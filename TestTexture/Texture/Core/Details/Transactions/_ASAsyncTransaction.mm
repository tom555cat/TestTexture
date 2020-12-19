//
//  _ASAsyncTransaction.m
//  TestTexture
//
//  Created by tom555cat on 2020/12/19.
//

#import "_ASAsyncTransaction.h"

@interface ASAsyncTransactionOperation : NSObject

// 初始化了一个completionBlock，那么executionBlock哪去了？
- (instancetype)initWithOperationCompletionBlock:(asyncdisplaykit_async_transaction_operation_completion_block_t)operationCompletionBlock;
@property (nonatomic) asyncdisplaykit_async_transaction_operation_completion_block_t operationCompletionBlock;
@property id value; // set on bg queue by the operation block  暂时不知道干什么用

@end

@implementation ASAsyncTransactionOperation

- (instancetype)initWithOperationCompletionBlock:(asyncdisplaykit_async_transaction_operation_completion_block_t)operationCompletionBlock
{
  if ((self = [super init])) {
    _operationCompletionBlock = operationCompletionBlock;
  }
  return self;
}

- (void)dealloc
{
    // 确保completionBlock已经被释放掉
#warning 如何确保这一点？为什么要确保这一点?
  NSAssert(_operationCompletionBlock == nil, @"Should have been called and released before -dealloc");
}

- (void)callAndReleaseCompletionBlock:(BOOL)canceled;
{
  // ASDisplayNodeAssertMainThread();   必须在主线程上执行completionBlock，符合"_ASAsyncTransaction"的要求
  if (_operationCompletionBlock) {
    _operationCompletionBlock(self.value, canceled);
    // Guarantee that _operationCompletionBlock is released on main thread
#warning 确保在主线程上被释放，因为可能涉及到一些UIKit的东西
    _operationCompletionBlock = nil;
  }
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ASAsyncTransactionOperation: %p - value = %@>", self, self.value];
}

@end

// 为_ASAsyncTransaction提供的轻量级的operation queue，以限制spawned的线程
class ASAsyncTransactionQueue
{
public:
    
    // 类似于dispatch_group_t
    class Group
    {
    public:
        // 当group不再被需要时调用；在派发完最后一个operation之后，group会删除掉自己
        virtual void release() = 0;
        
        // 将block派发到指定的queue上
        virtual void schedule(NSInteger priority, dispatch_queue_t queue, dispatch_block_t block) = 0;
        
        // 将block派发到指定的queue上，当前边所有的安排的blocks结束执行
        virtual void notify(dispatch_queue_t queue, dispatch_block_t block) = 0;
        
        // 手动执行block的时候使用
        virtual void enter() = 0;
        virtual void leave() = 0;
        
        // 等待直到所有安排的block执行结束
        virtual void wait() = 0;
        
    protected:
        virtual ~Group() { };  // call release() instead
    };
    
    // 创建一个新的group
    Group *createGroup();
    
    static ASAsyncTransactionQueue &instance();
    
private:
    
    struct GroupNotify
    {
        dispatch_block_t _block;
        dispatch_queue_t _queue;
    };
    
    class GroupImpl : public Group
    {
    public:
        GroupImpl(ASAsyncTransactionQueue &queue)
        : _pendingOperations(0)
        , _releaseCalled(false)
        , _queue(queue)
        {
        }
        
        virtual void schedule(NSInteger priority, dispatch_queue_t queue, dispatch_block_t block);
        
        // 和Group关联的operation数量
        int _pendingOperations;
        std::list<GroupNotify> _notifyList;
        std::condition_variable _condition;
        BOOL _releaseCalled;
        ASAsyncTransactionQueue &_queue;
    };
    
    struct Operation
    {
        dispatch_block_t _block;
        GroupImpl *_group;
        NSInteger _priority;
    };
    
    struct DispatchEntry    // entry for each dispatch queue
    {
        typedef std::list<Operation> OperationQueue;
        typedef std::list<OperationQueue::iterator> OperationIteratorList; // each item points to operation queue
        typedef std::map<NSInteger, OperationIteratorList> OperationPriorityMap; // sorted by priority
        
        OperationQueue _operationQueue;
        OperationPriorityMap _opertionPriorityMap;
        int _threadCount;
        
        Operation popNextOperation(bool respectPriority);  // assumes locked mutex
        void pushOperation(Operation operation);           // assumes locked mutex
    };
    
    // 不同的队列上有不同的operation队列
    std::map<dispatch_queue_t, DispatchEntry> _entries;
    // _mutex就是保护上述_entries的
    std::mutex _mutex;
};

ASAsyncTransactionQueue & ASAsyncTransactionQueue::instance()
{
    static ASAsyncTransactionQueue *instance = new ASAsyncTransactionQueue();
    return *instance;
}

void ASAsyncTransactionQueue::GroupImpl::schedule(NSInteger priority, dispatch_queue_t queue, dispatch_block_t block)
{
    ASAsyncTransactionQueue &q = _queue;
    std::lock_guard<std::mutex> l(q._mutex);
    
    // 根据queue找到任务列表
    DispatchEntry &entry = q._entries[queue];
    
    Operation operation;
    operation._block = block;
    operation._group = this;   // 每个execution block和一个group绑定在一起
    operation._priority = priority;
    entry.pushOperation(operation);
    
    ++_pendingOperations;
    
#if ASDISPLAYNODE_DELAY_DISPLAY
    NSUInteger maxThreads = 1;
#else
    // 限制线程数量
    NSUInteger maxThreads = [NSProcessInfo processInfo].activeProcessorCount * 2;
    
    // Bit questionable maybe - we can give main thread more CPU time during tracking.
    if ([[NSRunLoop mainRunLoop].currentMode isEqualToString:UITrackingRunLoopMode])
        --maxThreads;
#endif
    
    if (entry._threadCount < maxThreads) {   // 线程数量少于最大限制，就在多开些线程
        
        bool respectPriority = entry._threadCount > 0;
        ++entry._threadCount;
        
        dispatch_async(queue, ^{
            std::unique_lock<std::mutex> lock(q._mutex);
            
            // go until there are no more pending operations
            while (!entry._operationQueue.empty()) {
                Operation operation = entry.popNextOperation(respectPriority);
                lock.unlock();
                if (operation._block) {
                    operation._block();
                }
                operation._group->leave();
                operation._block = nil; // the block must be freed while mutex is unlocked
                lock.lock();
            }
            --entry._threadCount;
            
            if (entry._threadCount == 0) {
              NSCAssert(entry._operationQueue.empty() || entry._operationPriorityMap.empty(), @"No working threads but operations are still scheduled"); // this shouldn't happen
              q._entries.erase(queue);
            }
        });
    }
}

@implementation _ASAsyncTransaction
{
    ASAsyncTransactionQueue::Group *_group;
    NSMutableArray<ASAsyncTransactionOperation *> *_operations;
}

#pragma mark - Transaction Management

- (void)addOperationWithBlock:(asyncdisplaykit_async_transaction_operation_block_t)block
                     priority:(NSInteger)priority queue:(dispatch_queue_t)queue
                   completion:(asyncdisplaykit_async_transaction_operation_completion_block_t)completion
{
    // ASDisplayNodeAssertMainThread();  断言，必须运行在主线程上
    NSAssert(self.state == ASAsyncTransactionStateOpen, @"You can only add operations to open transactions");
    
    // 懒创建_group和_operations
    [self _ensureTransactionData];
    
    ASAsyncTransactionOperation *operation = [[ASAsyncTransactionOperation alloc] initWithOperationCompletionBlock:completion];
    [_operations addObject:operation];
    _group->schedule(priority, queue, ^{
        @autoreleasepool {
            if (self.state != ASAsyncTransactionStateCanceled) {
                operation.value = block();
            }
        }
    });
}

#pragma mark - Helper Methods

- (void)_ensureTransactionData
{
    // 延迟初始化_group和_operations，来避免没有operations被加入到transaction时而需要创建这两项的overhead。
    if (_group == NULL) {
        _group = ASAsyncTransactionQueue::instance().createGroup();
    }
    if (_operations == nil) {
        _operations = [[NSMutableArray alloc] init];
    }
}

@end
