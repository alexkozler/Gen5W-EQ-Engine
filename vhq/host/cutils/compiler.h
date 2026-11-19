#pragma once
#define CC_LIKELY(exp) (__builtin_expect(!!(exp), 1))
#define CC_UNLIKELY(exp) (__builtin_expect(!!(exp), 0))
