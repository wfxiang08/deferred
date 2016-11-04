#import "KSPromise.h"


#if OS_OBJECT_USE_OBJC_RETAIN_RELEASE == 0
#   define KS_DISPATCH_RELEASE(q) (dispatch_release(q))
#else
#   define KS_DISPATCH_RELEASE(q)
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@interface KSPromiseCallbacks : NSObject

@property (copy, nonatomic) promiseValueCallback fulfilledCallback;
@property (copy, nonatomic) promiseErrorCallback errorCallback;

@property (copy, nonatomic) deferredCallback deprecatedFulfilledCallback;
@property (copy, nonatomic) deferredCallback deprecatedErrorCallback;
@property (copy, nonatomic) deferredCallback deprecatedCompleteCallback;

@property (strong, nonatomic) KSPromise *childPromise;

@end


NSString *const KSPromiseWhenErrorDomain = @"KSPromiseJoinError";
NSString *const KSPromiseWhenErrorErrorsKey = @"KSPromiseWhenErrorErrorsKey";
NSString *const KSPromiseWhenErrorValuesKey = @"KSPromiseWhenErrorValuesKey";


@implementation KSPromiseCallbacks

- (id)initWithFulfilledCallback:(promiseValueCallback)fulfilledCallback
                  errorCallback:(promiseErrorCallback)errorCallback
                    cancellable:(id<KSCancellable>)cancellable {
    self = [super init];
    if (self) {
        self.fulfilledCallback = fulfilledCallback;
        self.errorCallback = errorCallback;
        self.childPromise = [[KSPromise alloc] init];
        [self.childPromise addCancellable:cancellable];
    }
    return self;
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
@interface KSPromise () <KSCancellable> {
    dispatch_semaphore_t _sem;
}


// 重新定义属性
@property (strong, nonatomic, readwrite) id value;
@property (strong, nonatomic, readwrite) NSError *error;

@property (assign, nonatomic) BOOL fulfilled;
@property (assign, nonatomic) BOOL rejected;
@property (assign, nonatomic) BOOL cancelled;

// 定义新的属性
@property (strong, nonatomic) NSHashTable *cancellables;

@property (strong, nonatomic) NSMutableArray *callbacks;
@property (copy, nonatomic) NSArray *parentPromises;

@end

@implementation KSPromise

- (id)init {
    self = [super init];
    if (self) {
        self.callbacks = [NSMutableArray array];
        self.cancellables = [NSHashTable weakObjectsHashTable];
        // 如何创建: semaphore
        // 个数为0又如何使用呢?
        _sem = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)dealloc {
    KS_DISPATCH_RELEASE(_sem);
}

+ (KSPromise *)promise:(void (^)(resolveType resolve, rejectType reject))promiseCallback {
    KSPromise *promise = [[KSPromise alloc] init];
    // 如何理解呢?
    // 执行: promiseCallback 函数，然后调用: KSPromise 的#resolveWithValue, #rejectWithError
    // 而: KSPromise 的方法可以在外部定制
    //    promiseCallback 必须是异步的, 否则同步的调用会让 KSPromise来不及设置自己的属性
    promiseCallback(
    ^(id value){
        [promise resolveWithValue:value];
    },
    ^(NSError *error) {
        [promise rejectWithError:error];
    });

    return promise;
}

+ (KSPromise *)resolve:(id)value {
    KSPromise *promise = [[KSPromise alloc] init];
    [promise resolveWithValue:value];
    return promise;
}

+ (KSPromise *)reject:(NSError *)error {
    KSPromise *promise = [[KSPromise alloc] init];
    [promise rejectWithError:error];
    return promise;
}

+ (KSPromise *)when:(NSArray *)promises {
    KSPromise *promise = [[KSPromise alloc] init];
    promise.parentPromises = promises;

    if ([promise.parentPromises count] == 0) {
        [promise joinedPromiseFulfilled:nil];
    }
    else {
        for (KSPromise *joinedPromise in promises) {
            for (id<KSCancellable> cancellable in joinedPromise.cancellables) {
                [promise addCancellable:cancellable];
            }
            [joinedPromise finally:^ {
                [promise joinedPromiseFulfilled:joinedPromise];
            }];
        }
    }
    return promise;
}

+ (KSPromise *)all:(NSArray *)promises {
    return [self when:promises];
}

+ (KSPromise *)join:(NSArray *)promises {
    return [self when:promises];
}

// 如何Chain Promise呢?
- (KSPromise *)then:(promiseValueCallback)fulfilledCallback
              error:(promiseErrorCallback)errorCallback {
    
    // 如果当前的Promise
    if (self.cancelled) return nil;
    
    // 创建新的Callbacks
    if (![self completed]) {
        KSPromiseCallbacks *callbacks = [[KSPromiseCallbacks alloc] initWithFulfilledCallback:fulfilledCallback
                                                                                errorCallback:errorCallback
                                                                                  cancellable:self];
        [self.callbacks addObject:callbacks];
        
        // 返回: ChildPromise
        return callbacks.childPromise;
    }

    // 如果已经完成，则直接返回一个已经 resolved的KSPromise
    id nextValue;
    if (self.fulfilled) {
        nextValue = self.value;
        if (fulfilledCallback) {
           nextValue = fulfilledCallback(self.value);
        }
    } else if (self.rejected) {
        nextValue = self.error;
        if (errorCallback) {
            nextValue = errorCallback(self.error);
        }
    }
    KSPromise *promise = [[KSPromise alloc] init];
    [promise addCancellable:self];
    [self resolvePromise:promise withValue:nextValue];
    return promise;
}

// 简化写法
- (KSPromise *)then:(promiseValueCallback)fulfilledCallback {
    return [self then:fulfilledCallback error:nil];
}
// 简化写法
- (KSPromise *)error:(promiseErrorCallback)errorCallback {
    return [self then:nil error:errorCallback];
}

// 添加一个callback, 不管什么情况下都执行
- (KSPromise *)finally:(void(^)())callback {
    return [self then:^id (id value) {
        callback();
        return value;
    } error:^id (NSError *error) {
        callback();
        return error;
    }];
}

- (void)addCancellable:(id<KSCancellable>)cancellable
{
    [self.cancellables addObject:cancellable];
}

// 取消 Promise
- (void)cancel {
    self.cancelled = YES;
    // 回调每一个cancellables
    for (id<KSCancellable> cancellable in self.cancellables) {
        [cancellable cancel];
    }
    
    // callbacks直接删除?
    [self.callbacks removeAllObjects];
}

// 永远等待
- (id)waitForValue {
    return [self waitForValueWithTimeout:0];
}

- (id)waitForValueWithTimeout:(NSTimeInterval)timeout {
    // 超时等待
    if (![self completed]) {
        dispatch_time_t time = timeout == 0 ? DISPATCH_TIME_FOREVER : dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC);
        dispatch_semaphore_wait(_sem, time); // 等待完成
    }
    
    // 返回value或error
    if (self.fulfilled) {
        return self.value;
    } else if (self.rejected) {
        return self.error;
    }
    
    // 否则返回超时的错误
    return [NSError errorWithDomain:@"KSPromise" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Timeout exceeded while waiting for value"}];
}

#pragma mark - Resolving and Rejecting

// Creating a resolved promise
- (void)resolveWithValue:(id)value {
    NSAssert(!self.completed, @"A fulfilled promise can not be resolved again.");
    if (self.completed || self.cancelled) return;
    
    
    // 直接标志成功
    // 并且有value
    self.value = value;
    self.fulfilled = YES;
    
    // 如何理解各种callbacks呢?
    for (KSPromiseCallbacks *callbacks in self.callbacks) {
        id nextValue = self.value;
        
        // 如果有: fulfilledCallback 则调用
        if (callbacks.fulfilledCallback) {
            nextValue = callbacks.fulfilledCallback(value);
        } else if (callbacks.deprecatedFulfilledCallback) {
            callbacks.deprecatedFulfilledCallback(self);
            continue;
        }
        
        // 将value传递给childPromise
        // value是否可能为: Error呢?
        [self resolvePromise:callbacks.childPromise withValue:nextValue];
    }
    [self finish];
}

- (void)rejectWithError:(NSError *)error {
    NSAssert(!self.completed, @"A fulfilled promise can not be rejected again.");
    if (self.completed || self.cancelled) return;
    
    self.error = error;
    self.rejected = YES;
    
    // 将error传递给所有的callbacks, 以及它们对应的childPromise
    for (KSPromiseCallbacks *callbacks in self.callbacks) {
        id nextValue = self.error;
        if (callbacks.errorCallback) {
            nextValue = callbacks.errorCallback(error);
        } else if (callbacks.deprecatedErrorCallback) {
            callbacks.deprecatedErrorCallback(self);
            continue;
        }
        [self resolvePromise:callbacks.childPromise withValue:nextValue];
    }
    [self finish];
}

- (void)resolvePromise:(KSPromise *)promise withValue:(id)value {
    if ([value isKindOfClass:[KSPromise class]]) {
        [value then:^id(id value) {
            [promise resolveWithValue:value];
            return value;
        } error:^id(NSError *error) {
            [promise rejectWithError:error];
            return error;
        }];
    } else if ([value isKindOfClass:[NSError class]]) {
        [promise rejectWithError:value];
    } else {
        [promise resolveWithValue:value];
    }
}

- (void)finish {
    for (KSPromiseCallbacks *callbacks in self.callbacks) {
        if (callbacks.deprecatedCompleteCallback) {
            callbacks.deprecatedCompleteCallback(self);
        }
    }
    
    [self.callbacks removeAllObjects];
    // 通知其他的线程，可以继续执行了
    dispatch_semaphore_signal(_sem);
}

- (BOOL)completed {
    return self.fulfilled || self.rejected;
}

#pragma mark - Deprecated methods
- (void)whenResolved:(deferredCallback)callback {
    if (self.fulfilled) {
        callback(self);
    } else if (!self.cancelled) {
        KSPromiseCallbacks *callbacks = [[KSPromiseCallbacks alloc] init];
        callbacks.deprecatedFulfilledCallback = callback;
        [self.callbacks addObject:callbacks];
    }
}

- (void)whenRejected:(deferredCallback)callback {
    if (self.rejected) {
        callback(self);
    } else if (!self.cancelled) {
        KSPromiseCallbacks *callbacks = [[KSPromiseCallbacks alloc] init];
        callbacks.deprecatedErrorCallback = callback;
        [self.callbacks addObject:callbacks];
    }
}

- (void)whenFulfilled:(deferredCallback)callback {
    if ([self completed]) {
        callback(self);
    } else if (!self.cancelled) {
        KSPromiseCallbacks *callbacks = [[KSPromiseCallbacks alloc] init];
        callbacks.deprecatedCompleteCallback = callback;
        [self.callbacks addObject:callbacks];
    }
}

#pragma mark - Private methods
- (void)joinedPromiseFulfilled:(KSPromise *)promise {
    if ([self completed]) {
        return;
    }
    
    BOOL fulfilled = YES;
    NSMutableArray *errors = [NSMutableArray array];
    NSMutableArray *values = [NSMutableArray array];
    
    for (KSPromise *joinedPromise in self.parentPromises) {
        fulfilled = fulfilled && joinedPromise.completed;
        // 统计Error 和 Values
        // 如果失败了, Values似乎不太重要?
        if (joinedPromise.rejected) {
            id error = joinedPromise.error ? joinedPromise.error : [NSNull null];
            [errors addObject:error];
        } else if (joinedPromise.fulfilled) {
            id value = joinedPromise.value ? joinedPromise.value : [NSNull null];
            [values addObject:value];
        }
    }
    
    // 如果执行了，则回调:
    if (fulfilled) {
        if (errors.count > 0) {
            NSDictionary *userInfo = @{KSPromiseWhenErrorErrorsKey: errors,
                                       KSPromiseWhenErrorValuesKey: values};
            NSError *whenError = [NSError errorWithDomain:KSPromiseWhenErrorDomain
                                                     code:1
                                                 userInfo:userInfo];
            [self rejectWithError:whenError];
        } else {
            [self resolveWithValue:values];
        }
    }
}

@end
