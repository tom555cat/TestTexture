//
//  _ASAsyncTransaction.h
//  TestTexture
//
//  Created by tom555cat on 2020/12/19.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef id<NSObject> _Nullable(^asyncdisplaykit_async_transaction_operation_block_t)(void);
typedef void(^asyncdisplaykit_async_transaction_operation_completion_block_t)(id _Nullable value, BOOL canceled);

/**
 State初始化为ASAsyncTransactionStateOpen。
 每个transaction必须被commited。commit transaction失败是个error。
 commited的transaction可能会被取消。不能取消一个open(uncommited)transaction。
 */
typedef NS_ENUM(NSUInteger, ASAsyncTransactionState) {
  ASAsyncTransactionStateOpen = 0,
  ASAsyncTransactionStateCommitted,
  ASAsyncTransactionStateCanceled,
  ASAsyncTransactionStateComplete
};

/**
 @summary ASAsyncTransaction为异步操作提供了一个轻量级的transction semantics。
 
 @desc ASAsyncTransaction提供如下属性：

 - Transactions组织了任意数量的operations，每个operation包含一个execution block和completion block。
 - execution block返回一个单一对象，这个对象会被传递进completion block。
 - 加入到transaction的execution block会并行地运行在global background dispatch queues；而completion blocks会被派发到callback queue上。
 - 每个operation的completion block确保会执行，“不会被取消”。然而，如果transaction被取消的话execution blocks可能会被跳过。
 - operation的completion blocks总是以它们被加入transaction的顺序去执行的，如果callback queue是个串行队列。
 */
@interface _ASAsyncTransaction : NSObject

/**
 transaction的状态。
 @see ASAsyncTransactionState
 */
@property (readonly) ASAsyncTransactionState state;

/**
 @summary 在transaction中添加一个同步的operation，execution block会立即执行。
 
 @desc block会在指定的queue上执行，并且同步地完成。异步的transaction会等待所有的operations在各自合适的队列上执行，‘
 所以如果blocks在并发队列上执行时，blocks可能仍然是异步执行，即使block的工作使同步的。
 */
- (void)addOperationWithBlock:(asyncdisplaykit_async_transaction_operation_block_t)block
                     priority:(NSInteger)priority
                        queue:(dispatch_queue_t)queue
                   completion:(nullable asyncdisplaykit_async_transaction_operation_completion_block_t)completion;

@end

NS_ASSUME_NONNULL_END
