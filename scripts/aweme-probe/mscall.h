#import <Foundation/Foundation.h>

// 日志回调：mscall 内部不直接依赖 main.m 的 logline
typedef void (*ms_log_fn)(const char *utf8);

// 分步执行：每一步都可能让进程崩溃（AwemeCore 内部空指针无法用 @try 捕获），
// 所以按步编号执行，调用方负责把"已完成的步号"落盘，下次启动从断点继续。
int  ms_step_count(void);
void ms_step(int step, ms_log_fn sink);
