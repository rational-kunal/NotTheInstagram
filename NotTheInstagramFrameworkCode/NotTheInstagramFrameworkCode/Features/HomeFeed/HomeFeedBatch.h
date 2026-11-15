#import <Foundation/Foundation.h>

static inline NSTimeInterval NTIHomeFeedLoaderDuration(NSUInteger completedWaits) {
    return 8 + 3 * MIN(completedWaits, 2);
}

// Keep any interleaved feed modules with their original neighbors.
static inline NSUInteger NTIHomeFeedBatchCutoff(NSArray *objects, NSUInteger revealedPosts,
                                                NSUInteger *presentedPosts, BOOL (^isPost)(id)) {
    NSUInteger posts = 0;
    NSUInteger cutoff = objects.count;
    for (NSUInteger index = 0; index < objects.count; index++) {
        if (!isPost(objects[index])) continue;
        posts++;
        if (posts == revealedPosts) cutoff = index + 1;
        if (posts > revealedPosts) {
            *presentedPosts = revealedPosts;
            return cutoff;
        }
    }
    *presentedPosts = posts;
    return objects.count;
}
