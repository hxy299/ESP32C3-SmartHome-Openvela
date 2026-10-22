/****************************************************************************
 * arch/risc-v/src/esp32c3/esp_atomic_stubs.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * ESP32-C3-SmartHome-Actuator 移植补充
 *
 * rv32imc 没有 A 扩展（无原子指令），GCC 会把 __atomic_* 内建函数
 * 降级为对 libatomic 的调用。Espressif 的 riscv32-esp-elf 工具链
 * 默认不提供 libatomic.a，因此这里给出实现。
 *
 * ESP32-C3 是单 hart，用"关中断"即可满足原子性要求。
 *
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <stdbool.h>
#include <stdint.h>

#include <nuttx/irq.h>
#include <nuttx/spinlock.h>

/****************************************************************************
 * Pre-processor Definitions
 ****************************************************************************/

#define ATOMIC_ENTER()   enter_critical_section()
#define ATOMIC_LEAVE(f)  leave_critical_section(f)

/****************************************************************************
 * Public Functions
 ****************************************************************************/

#define DEFINE_FETCH_OP(name, op) \
  uint32_t __atomic_fetch_##name##_4(FAR volatile void *ptr, uint32_t val, \
                                     int memorder) \
  { \
    irqstate_t flags = ATOMIC_ENTER(); \
    FAR volatile uint32_t *p = (FAR volatile uint32_t *)ptr; \
    uint32_t old = *p; \
    *p = old op val; \
    ATOMIC_LEAVE(flags); \
    return old; \
  }

DEFINE_FETCH_OP(add, +)
DEFINE_FETCH_OP(sub, -)
DEFINE_FETCH_OP(and, &)
DEFINE_FETCH_OP(or,  |)
DEFINE_FETCH_OP(xor, ^)

uint32_t __atomic_exchange_4(FAR volatile void *ptr, uint32_t val, int memorder)
{
  irqstate_t flags = ATOMIC_ENTER();
  FAR volatile uint32_t *p = (FAR volatile uint32_t *)ptr;
  uint32_t old = *p;
  *p = val;
  ATOMIC_LEAVE(flags);
  return old;
}

bool __atomic_compare_exchange_4(FAR volatile void *ptr,
                                 FAR void *expected, uint32_t desired,
                                 bool weak, int success_memorder,
                                 int failure_memorder)
{
  irqstate_t flags = ATOMIC_ENTER();
  FAR volatile uint32_t *p = (FAR volatile uint32_t *)ptr;
  FAR uint32_t *e = (FAR uint32_t *)expected;
  bool ret = false;

  if (*p == *e)
    {
      *p  = desired;
      ret = true;
    }
  else
    {
      *e = *p;
    }

  ATOMIC_LEAVE(flags);
  return ret;
}
