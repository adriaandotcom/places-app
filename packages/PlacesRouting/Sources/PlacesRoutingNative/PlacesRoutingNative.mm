#import "PlacesRoutingNative.h"
#include <include/valhalla_actor.h>
#include <valhalla/midgard/logging.h>
#include <date/tz.h>
#include <memory>
#include <mutex>

@implementation PLPlacesValhalla {
    std::unique_ptr<ValhallaActor> _actor;
}

static void report(NSError **error, NSInteger code) {
    if (error) {
        // Native error strings can contain input locations or paths. Keep them out
        // of ordinary diagnostics and UI; the host reports only bounded statuses.
        *error = [NSError errorWithDomain:@"PlacesRouting" code:code
                                userInfo:@{NSLocalizedDescriptionKey: @"Could not match this trace locally."}];
    }
}

- (instancetype)initWithConfigPath:(NSString *)configPath timezonePath:(NSString *)timezonePath
                             error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        static std::once_flag initialized;
        std::call_once(initialized, [&] {
            // Configure before GraphReader or any action can initialize its logger.
            valhalla::midgard::logging::Configure({{"type", ""}});
            date::set_install(timezonePath.UTF8String);
        });
        _actor = std::make_unique<ValhallaActor>(configPath.UTF8String, nullptr);
        return self;
    } catch (...) {
        report(error, 1);
        return nil;
    }
}

- (NSString *)traceAttributes:(NSString *)request error:(NSError **)error {
    @synchronized(self) {
        if (!_actor) { report(error, 2); return nil; }
        try {
            auto result = _actor->trace_attributes(request.UTF8String);
            NSString *text = [[NSString alloc] initWithBytes:result.data() length:result.size()
                                                  encoding:NSUTF8StringEncoding];
            if (!text) report(error, 3);
            return text;
        } catch (...) {
            report(error, 4);
            return nil;
        }
    }
}

- (void)close {
    @synchronized(self) { _actor.reset(); }
}
@end
