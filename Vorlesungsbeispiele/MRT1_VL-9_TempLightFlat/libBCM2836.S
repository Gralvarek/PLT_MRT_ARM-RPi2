@ Header
.globl BCM2836_Open, BCM2836_Close, BCM2836_GPIO_PinSelFun, BCM2836_GPIO_PinSet, BCM2836_GPIO_PinClr, BCM2836_GPIO_PinSelDump
.globl BCM2836_SPI0_GetBase, BCM2836_SPI0_Init, BCM2836_SPI0_Send

.include "BCM2836_constants.h"
.include "BCM2836_GPIO_constants.h"
.include "BCM2836_SPI_constants.h"
.include "SYSCALL.h"

.data
.balign 4
dev_mem_filename:     .asciz "/dev/mem"
.balign 4
BCM2836_msg_err_open: .asciz "error initializing BCM2836"
.balign 4
dev_mem_gpio_fd:         .word 0  @ holds fd to /dev/mem
dev_mem_gpio_base_addr:  .word 0

.equ BCM2836_strlen_err_open, . - BCM2836_msg_err_open

.text
.align 4

/*********************
 * General BCM2836 Functions
 *********************/

.func BCM2836_Open
BCM2836_Open:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  // dev_mem_gpio_fd = open(/dev/mem,  O_RDWR|O_SYNC, 0)
  ldr r0, =dev_mem_filename
  ldr r1, =OPEN_PARAMETER_SYNC_RDWR
  mov r2, #0
  mov r7, #SYSCALL_OPEN
  swi #0
  ldr r1,=dev_mem_gpio_fd  @ save file-handle at =dev_mem_gpio_fd
  str r0,[r1]
  cmp r0,#0
  ble BCM2836_Open_error

  // mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
  // dev_mem_gpio_base_addr = mmap(NULL, gpio_speicherbereich, PROT_READ|PROT_WRITE, MAP_SHARED)
  mov r4, r0
  mov r0, #0
  mov r1, #BCM2836_PERI_MAPSIZE
  mov r2, #MMAP_PARAMETER_PROT_READ_WRITE
  mov r3, #MMAP_PARAMETER_MAP_SHARED
  ldr r5, =BCM2836_GPIO_BASE        // mmap benutzt 4k bloecke und multipliziert unsere adresse intern; wir muessen etwas schieben
  lsr r5, r5, #12                   // aus 0x3f200000 sollte 0x3f200 werden...
  mov r7, #SYSCALL_MMAP2
  swi #0
  ldr r1,=dev_mem_gpio_base_addr  // save address at =dev_mem_gpio_addr
  str r0,[r1]
  cmp r0,#0
  movne r0,#0
BCM2836_Open_exit:
  ldmfd sp!,{r4-r10,r11,lr}
  bx lr

BCM2836_Open_error:
  push {r0,r7}
  mov r0,#1 // stdout
  ldr r1,=BCM2836_msg_err_open
  mov r2,#BCM2836_strlen_err_open
  mov r7,#SYSCALL_WRITE
  swi #0

  ldmfd sp!,{r4-r10,r11,lr}
  bal BCM2836_Open_exit
.endfunc

.func BCM2836_Close
BCM2836_Close:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

    // munmap
  ldr r0,=dev_mem_gpio_base_addr
  ldr r0,[r0]
  mov r1,#BCM2836_PERI_MAPSIZE
  mov r7,#SYSCALL_MUNMAP
  swi #0

  // close
  ldr r0,=dev_mem_gpio_fd
  ldr r0,[r0]
  mov r7, #SYSCALL_CLOSE
  swi #0

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

/*********************
 * GPIO Functions
 *********************/
// BCM2836_GPIO_PinSelFun(GPIO-Pin, FunctionSelection)
.func BCM2836_GPIO_PinSelFun
BCM2836_GPIO_PinSelFun:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  // r10 <- Index of GPFSELn register; r0 <- 10⁰ remainder of pin number
  // template: ablehnende schleife
  BCM2836_GPIO_PinSelFun_divloop_init:
  // while (r9:div=0, r0:mod=27); r0 = value --> value%10; r9=value/10
  mov r9, #0
  BCM2836_GPIO_PinSelFun_divloop_test:
    // Subtrahiere, solange r0 positiv ist
    subs r0, r0, #10
    bmi  BCM2836_GPIO_PinSelFun_divloop_done
    add  r9, r9, #1
    b    BCM2836_GPIO_PinSelFun_divloop_test
  BCM2836_GPIO_PinSelFun_divloop_done:
  add r10, r0, #10 // r0 ist ins negative gerutsch, korrigiere letzte subraktion
  add r10, r10, r10, lsl #1 // r0 ist ins negative gerutsch, korrigiere letzte subraktion
  // r10: (GPIONr%10)*3; Shift-bits in FSEL
  // r9:  GPIONr/10

  /* Copy - ... */
  ldr r3,=dev_mem_gpio_base_addr
  ldr r3,[r3]   // R3 <- address of gpio_base

  ldr r4,[r3,r9,LSL #2]   // R4 <- [ GPFSEL<r2> ]

  /* ... - Modify - ...*/
  mov r5,#0b111
  bic r4,r4,r5,LSL R10  // R4 <- R4 AND NOT ( 0b111 << R10)
  orr r4,r4,r1,LSL R10 // R4 <- R4 ORR R1

  /* ... - Update*/
  str r4,[r3,r9,LSL #2] // R4 -> [ GPFSEL<r2> ]

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

// void BCM2836_GPIO_PinSet(GPIO_Pin)
.func BCM2836_GPIO_PinSet
BCM2836_GPIO_PinSet:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  // r1 <- Offset to GPSET0 or GPSET1
  mov r1,#BCM2836_GPSET_OFFSET
  cmp r0,#31      // if (R0 > 31)
  addgt r1,r1,#4  // R1 <- R1 + 4

  // r0 <- 1 << ( pin % 32)
  and r0, r0, #0x1F  // pin % 32
  mov r3, #1
  lsl r0, r3, r0     // 1 << ( pin % 32)

  // r2 <- gpio_base_addr
  ldr r2,=dev_mem_gpio_base_addr
  ldr r2,[r2]

  // r0 -> [base + offset]
  str r0,[r2,r1]

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

// void BCM2836_GPIO_PinClr(GPIO_Pin)
.func BCM2836_GPIO_PinClr
BCM2836_GPIO_PinClr:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  // r1 <- Offset to GPCLR0 or GPCLR1
  mov r1,#BCM2836_GPCLR_OFFSET
  cmp r0,#31      // if (R0 > 31)
  addgt r1,r1,#4  //  R1 <- R1 + 4

  // r0 <- ( b1 << ( PIN % 32 ))
  and r0, r0, #0x1F
  mov r3, #1
  mov r0, r3, LSL r0

  // r2 <- gpio_base_addr
  ldr r2,=dev_mem_gpio_base_addr
  ldr r2,[r2]

  // r0 -> [gpio_base_addr + offset]
  str r0,[r2,r1]

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

/*********************
 * SPI Functions
 *
 * For documentation, see BCM2835 datasheet
 * chapter 10, page 148ff.
 *********************/
.func BCM2836_SPI0_GetBase
 /**
   * @brief: Returns the base address of the SPI0 registers in mapped memory
   *
   * Note that this function assumes you have initialized the peripheral.
   */
BCM2836_SPI0_GetBase:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  ldr r0,=dev_mem_gpio_base_addr
  ldr r0,[r0]
  add r0,r0,#(BCM2836_SPI0_BASEOFFSET-BCM2836_GPIO_BASEOFFSET)

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

// void bcm2836_spi_init(void)
.func BCM2836_SPI0_Init
  /**
   * @brief: Setup IO Pins for SPI0 (SoC), config SPI for MCP3008
   */
BCM2836_SPI0_Init:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  // FIXME: This bluntly assumes that GPIO_Init has been called!
  bl BCM2836_SPI0_GetBase
  mov r4, r0 // r4 = SPI Base

  // set pin functions to alternate0
  mov r0,#7 // CE1
  mov r1,#BCM2836_GPFSEL_ALT0
  bl BCM2836_GPIO_PinSelFun

  mov r0,#8 // CE0
  mov r1,#BCM2836_GPFSEL_ALT0
  bl BCM2836_GPIO_PinSelFun

  mov r0,#9 // MISO
  mov r1,#BCM2836_GPFSEL_ALT0
  bl BCM2836_GPIO_PinSelFun

  mov r0,#10 // MOSI
  mov r1,#BCM2836_GPFSEL_ALT0
  bl BCM2836_GPIO_PinSelFun

  mov r0,#11 // CLK
  mov r1,#BCM2836_GPFSEL_ALT0
  bl BCM2836_GPIO_PinSelFun

  // initialize CS
  mov r0, #0
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  // clear fifos
  mov r0,    #BCM2835_SPI0_CS_CLEAR
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  // set CS-Polarity of cs0 and cs1 to 0
  ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
  bic r0,r0,#BCM2835_SPI0_CS_CSPOL0
  bic r0,r0,#BCM2835_SPI0_CS_CSPOL1
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  // set data mode to mode 0 (cpol=0, cpha=0) and select CS0 (CS=0)
  ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
  bic r0,r0,#BCM2835_SPI0_CS_CPOL
  bic r0,r0,#BCM2835_SPI0_CS_CPHA
  bic r0,r0,#BCM2835_SPI0_CS_CS
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  // set clock divider
  mov r0,#64 // 3.9 MhZ on RPi2
  str r0,[r4,#BCM2835_SPI0_CLK_OFFSET]

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc

 // void bcm2836_spi0_send(size_t dataSz, void* txdata, void *rxdata)
 .func BCM2836_SPI0_Send
  /**
  * @brief: Send and receive dataSz bytes over SPI.
  *
  * @param dataSz  The number of bytes to be send from txdata
  * @param *txdata Points to a byte-wise memory buffer from which we read data
  * @param *rxdata Byte-wise memory buffer where we will store our data
  * @return        Nothing meaningful
  *
  * Assume *txdata points to dataSz bytes of data. proceed as follows:
  *
  * Clear RX/TX FiFos;
  * rxData = 0;
  * txData = 0;
  * while (rxData < dataSz) {
  *   if (txBuffer != Full && txData < dataSz)
  *     copy(txdata[txData++] to SPI TX Buffer);
  *   if (rxBuffer != Empty)
  *     copy(SPI RX Buffer to rxdata[rxData++])
  * }
  */
 BCM2836_SPI0_Send:
  // EABI first
  mov   ip, sp
  stmfd sp!,{r4-r11,lr}
  mov   fp, ip

  mov r7, r0  // dataSz:r7 = r0:dataSz
  bl BCM2836_SPI0_GetBase
  mov r4, r0  // r4 = BCM2836_SPI0_GetBase()
  mov r5, #0  // rxData:r5 = 0
  mov r6, #0  // txData:r6 = r0:dataSz
  mov r8, r1  // r8 = *txdata_ptr
  mov r9, r2  // r9 = *rxdata_ptr

  // clear fifos and set TA
  // CS = CS | (CLEAR|TA)
  ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
  orr r0,r0, #BCM2835_SPI0_CS_CLEAR
  orr r0,r0, #BCM2835_SPI0_CS_TA
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  // Template Ablehnende Schleife
  BCM2836_SPI0_Send_rxtxloop_start:
    // while (rxdata:r5 < dataSz:r7) ...
    cmp r5, r7
    bge BCM2836_SPI0_Send_rxtxloop_end

    // Template Selektion
    BCM2836_SPI0_Send_rxtxloop_rx:
      // if (rxBuffer != Empty) {
      ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
      tst r0, #BCM2835_SPI0_CS_RXD_FIFO_NOTEMPTY
      beq BCM2836_SPI0_Send_rxtxloop_rx_end

      // copy(SPI RX Buffer to rxdata[rxData++])
      ldr r0,[r4,#BCM2835_SPI0_FIFO_OFFSET] // read
      and r0,r0,#0xFF
      strb r0,[r9, r5]
      add r5, r5, #1 // rxData++
    BCM2836_SPI0_Send_rxtxloop_rx_end: // }

    // Template Selektion
    BCM2836_SPI0_Send_rxtxloop_tx:
      // if (txdata:r6 < dataSz:r7 ...
      cmp r6, r7
      bge BCM2836_SPI0_Send_rxtxloop_tx_end
      //  && txBuffer != Full ....
      ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
      tst r0, #BCM2835_SPI0_CS_TXD_FIFO_FULL
      beq BCM2836_SPI0_Send_rxtxloop_tx_end
      // ... ) {

      // copy(txdata[txData++] to SPI TX Buffer);
      ldrb r0, [r8, r6]
      str  r0, [r4, #BCM2835_SPI0_FIFO_OFFSET]
      add  r6, r6, #1  // txData++
    BCM2836_SPI0_Send_rxtxloop_tx_end: //}

    b BCM2836_SPI0_Send_rxtxloop_start
  BCM2836_SPI0_Send_rxtxloop_end:

  // while (!DONE) { wait }
  BCM2836_SPI0_Send_wait_for_done:
  ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET] // wait for done
  tst r0,#BCM2835_SPI0_CS_DONE
  beq BCM2836_SPI0_Send_wait_for_done

  // Set transmission active to 0 (disables output lines)
  ldr r0,[r4,#BCM2835_SPI0_CS_OFFSET]
  bic r0,r0,#BCM2835_SPI0_CS_TA
  str r0,[r4,#BCM2835_SPI0_CS_OFFSET]

  ldmfd sp!,{r4-r10,r11,lr}
  bx lr
.endfunc
