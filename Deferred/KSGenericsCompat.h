
#if __has_feature(objc_generics)
// 如何使用Generics
#define KS_GENERIC(GENERIC_TYPE) <GENERIC_TYPE>
#define KS_GENERIC_TYPE(GENERIC_TYPE) GENERIC_TYPE
#else
#define KS_GENERIC(GENERIC_TYPE)
#define KS_GENERIC_TYPE(GENERIC_TYPE) id
#endif
