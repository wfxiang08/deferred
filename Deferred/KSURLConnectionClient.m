#import "KSURLConnectionClient.h"
#import "KSPromise.h"

@implementation KSNetworkClient

// 每个请求使用独立的Connection, 不便于: http2.0协议?
- (KSPromise KS_GENERIC(KSNetworkResponse *) *)sendAsynchronousRequest:(NSURLRequest *)request
                                                                 queue:(NSOperationQueue *)queue {
    return [KSPromise promise:^(resolveType  _Nonnull resolve, rejectType  _Nonnull reject) {
        // 异步执行动作
        [NSURLConnection sendAsynchronousRequest:request
                                           queue:queue
                               completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            // 异步动作通过: resolve, reject来回调
            // 而: resolve, reject是由 KSPromise自己提供，是为了让自己的后续的callback能被调用
            if (error) {
                reject(error);
            } else {
                resolve([KSNetworkResponse networkResponseWithURLResponse:response                                                               data:data]);
            }
        }];
    }];
}

@end

@implementation KSURLConnectionClient
@end
