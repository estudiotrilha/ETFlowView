//
//  ETFlowView.m
//  InEvent
//
//  Created by Pedro Góes on 05/10/12.
//  Copyright (c) 2012 Pedro Góes. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "ETFlowView.h"

@interface ETFlowView () {
    BOOL isUpdating;
    BOOL isScrolling;
}

@end

@implementation ETFlowView

#pragma mark - Init

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self initParams];
    }
    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    [self initParams];
}

- (void)initParams {
    // Params
    _shouldBind = NO;
    _isMatrix = NO;
    _matrixHorizontalPadding = 0.0f;
    _matrixVerticalPadding = 0.0f;
    isUpdating = NO;
    isScrolling = NO;

    // Content
    self.contentSize = CGSizeMake(self.frame.size.width, self.frame.size.height);
    self.delegate = self;
	[self flashScrollIndicators];
}

#pragma mark - View Cycle

- (void)didAddSubview:(UIView *)subview {
    // KVO
    if (_shouldBind) [self registerRecursively:subview];
}

- (void)willRemoveSubview:(UIView *)subview {
    // KVO
    if (_shouldBind) [self unregisterRecursively:subview];
}

- (void)dealloc {
    // KVO
    if (_shouldBind) [self unregisterRecursively:self];
}

#pragma mark - Setters

- (void)setShouldBind:(BOOL)shouldBind {
    
    if (_shouldBind != shouldBind) {
        
        if (shouldBind == YES) {
            [self registerRecursively:self];
        } else {
            [self unregisterRecursively:self];
        }
        
        _shouldBind = shouldBind;
    }
}

#pragma mark - Private Methods

- (void)registerRecursively:(UIView *)masterView {
    
    // Register masterView
    [self addKeyPathObserver:masterView];
    
    // Register all views
    for (UIView *view in masterView.subviews) {
        [self registerRecursively:view];
    }
}

- (void)unregisterRecursively:(UIView *)masterView {
    
    // Unregister masterView
    [self removeKeyPathObserver:masterView];

    // Unregister all views
    for (UIView *view in masterView.subviews) {
        [self unregisterRecursively:view];
    }
}

#pragma mark - Public methods

- (void)updateView:(UIView *)view toFrame:(CGRect)newFrame {
    
    // Disables autoresizing
    UIViewAutoresizing autoResizing = view.autoresizingMask;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    // Update view frame
    CGRect oldFrame = view.frame;
    view.frame = newFrame;
    
    // Enables autoresizing
    // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    // Enables previous state
    view.autoresizingMask = autoResizing;
    // });

    // Update view hierarchy
    [self updateHierarchyForView:view fromOldFrame:oldFrame toNewFrame:newFrame];
}

#pragma mark - KVO methods

- (void)addKeyPathObserver:(UIView *)view {
    [view addObserver:self forKeyPath:@"frame" options:NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld context:NULL];
}

- (void)removeKeyPathObserver:(UIView *)view {
    
    @try {
        [view removeObserver:self forKeyPath:@"frame" context:NULL];
    }
    @catch (NSException * __unused exception) {
        // Nothing important, just log for know reasons
        NSLog(@"%@, %@", exception.name, exception.reason);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    // We cannot be on scroll mode
    if (!isScrolling) {
        
        // Make sure we are dealing with frames
        if ([keyPath isEqualToString:@"frame"]) {
            
            // Capture some properties
            CGRect newFrame = [[change objectForKey:NSKeyValueChangeNewKey] CGRectValue];
            CGRect oldFrame = [[change objectForKey:NSKeyValueChangeOldKey] CGRectValue];
            
            // See if we have a view
            if ([object isKindOfClass:[UIView class]]) {
                // Update hierarchy
                [self updateHierarchyForView:((UIView *)object) fromOldFrame:oldFrame toNewFrame:newFrame];
            }
        }
    }
    
}

#pragma mark - Resizing Methods
    
- (void)updateHierarchyForView:(UIView *)view fromOldFrame:(CGRect)oldFrame toNewFrame:(CGRect)newFrame {
    
    // Make sure our view is static at this moment
    if (!isUpdating) {
        
        // Get their delta
        CGFloat delta = newFrame.size.height - oldFrame.size.height;
        
        // Limit to relevant values
        if (delta != 0.0f) {
            isUpdating = YES;
            [self updateViewHeight:view basedOnFrame:CGRectZero by:delta];
            isUpdating = NO;
        }
    }
}

- (void)updateViewHeight:(UIView *)masterView basedOnFrame:(CGRect)innerFrame by:(CGFloat)delta {
    
    CGRect frame;
    CGFloat preHighestY = 0.0f, postHighestY = 0.0f;
    
    if ([masterView.superview.subviews count] > 0) {
        
        // Loop through all the siblings elements
        for (UIView *view in masterView.superview.subviews) {
            
            // Need to get highest position before any changes
            if (_isMatrix && !(view.alpha == 0.0f) && !(view.frame.size.height <= 0.0f)) {
                preHighestY = MAX(preHighestY, view.frame.origin.y);
            }
            
            /* Make sure that the position of the view inside a view with a reasonable height is not considered above an external but closer to top view.
             
             Let's draw an example:
             
             /////////     /////////
             /       /     /       /
             /       /  ///////////////
             /       /  / BBBBBBBBBBB /
             /  ///  /  ///////////////
             / /AAA/ /     /       /
             /  ///  /     /       /
             /       /     /       /
             /////////     /////////
            
             Even tough view's A parent has a smaller .y compared to view's B, view B shall not be moved, because externally it is above view A.
                
             We must also remember that depending upon the direction of the resize, we may need to take different actions:
             
                - if we are shrinking a view, we should ignore the ones that are on the same .y, otherwise they will all get decreased vertically forever.
                - if we are expanding a view, we can now take the views on the same .y and expand them since their .y will not be changed.
             
             */
            
            // Direction of our resizing (expanding/shrinking)
            BOOL originBoundaryLimit = NO;
            if (delta > 0)  {
                originBoundaryLimit = (view.frame.origin.y >= (masterView.frame.origin.y + innerFrame.origin.y));
            } else {
                originBoundaryLimit = (view.frame.origin.y > (masterView.frame.origin.y + innerFrame.origin.y));
            }
            
            // We should not resize our own view
            if (originBoundaryLimit && view != masterView) {
                
                // Disables autoresizing
                UIViewAutoresizing autoResizing = view.autoresizingMask;
                view.autoresizingMask = UIViewAutoresizingNone;
                
                // Update view frame
                frame = view.frame;
                frame.origin.y += delta;
                view.frame = frame;
                
                // Enables autoresizing
                // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                // Restore state
                view.autoresizingMask = autoResizing;
                // });
            }
        }
        
        // If we have a matrix, we should fit everything together
        if (_isMatrix) {
            
            // Create our references to track where we are
            CGFloat currentX = 0.0f, currentY = 0.0f;
            
            // We loop through all your elements and see which ones can be fit on other places
            for (UIView *view in masterView.superview.subviews) {
                
                // We must skip views which are invisible
                if (view.alpha == 0.0f) continue;
                if (view.frame.size.height <= 0.0f) continue;
                
                // See if it fits in a previous place
                if (currentX + view.frame.size.width > masterView.superview.frame.size.width) {
                    currentX = 0.0f;
                    currentY += (view.frame.size.height + _matrixVerticalPadding);
                }
                
                // Move it (or keep it in place)
                [view setFrame:CGRectMake(currentX, currentY, view.frame.size.width, view.frame.size.height)];
                
                // Highest position after all changes
                postHighestY = MAX(postHighestY, view.frame.origin.y);
                
                // Set our new cursor pointer
                currentX += (view.frame.size.width + _matrixHorizontalPadding);
            }
            
            // We must recalculate our delta based on the differences generated by the layout
            delta = (postHighestY - preHighestY);
        }
        
        // Resize our view content size or go through its childs
        UIView *superView = masterView.superview;
        
        // Cancel all resizing for now
        BOOL currentAutoresizesSubviews = superView.autoresizesSubviews;
        superView.autoresizesSubviews = NO;
        
        // Make our superviews perfect fit
        if (superView == self) {
            // Only need to update our content size
            self.contentSize = CGSizeMake(self.contentSize.width, self.contentSize.height + delta);
            
            // Resize our flow frame only if contentSize is now smaller than its frame
            if (self.contentSize.height < superView.frame.size.height) {
                frame = superView.frame;
                frame.size.height += delta;
                superView.frame = frame;
            }
            
        } else {
            
            // Resize the superview frame
            frame = superView.frame;
            frame.size.height += delta;
            superView.frame = frame;
            
            // Update parent views
            [self updateViewHeight:superView basedOnFrame:masterView.frame by:delta];
        }
        
        // Delay execution of an action for seconds.
        // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Reenable resizing previous state
        superView.autoresizesSubviews = currentAutoresizesSubviews;
        // });
    }
}

#pragma mark - ScrollView Delegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    isScrolling = YES;
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
    isScrolling = scrollView.decelerating;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    isScrolling = !decelerate;
}

@end
