//
//  WMPageController.m
//  WMPageController
//
//  Created by Mark on 15/6/11.
//  Copyright (c) 2015年 yq. All rights reserved.
//

#import "WMPageController.h"
#import "WMPageConst.h"

static CGFloat kWMMarginToNavigationItem = 6.0;
@interface WMPageController () {
    CGFloat _viewHeight, _viewWidth, _viewX, _viewY, _targetX, _superviewHeight;
    BOOL    _animate, _hasInited, _shouldNotScroll;
}
@property (nonatomic, strong, readwrite) UIViewController *currentViewController;
// 用于记录子控制器view的frame，用于 scrollView 上的展示的位置
@property (nonatomic, strong) NSMutableArray *childViewFrames;
// 当前展示在屏幕上的控制器，方便在滚动的时候读取 (避免不必要计算)
@property (nonatomic, strong) NSMutableDictionary *displayVC;
// 用于记录销毁的viewController的位置 (如果它是某一种scrollView的Controller的话)
@property (nonatomic, strong) NSMutableDictionary *posRecords;
// 用于缓存加载过的控制器
@property (nonatomic, strong) NSCache *memCache;
// 收到内存警告的次数
@property (nonatomic, assign) int memoryWarningCount;
@end

@implementation WMPageController

#pragma mark - Lazy Loading
- (NSMutableDictionary *)posRecords {
    if (_posRecords == nil) {
        _posRecords = [[NSMutableDictionary alloc] init];
    }
    return _posRecords;
}

- (NSMutableDictionary *)displayVC {
    if (_displayVC == nil) {
        _displayVC = [[NSMutableDictionary alloc] init];
    }
    return _displayVC;
}

#pragma mark - Public Methods

- (instancetype)initWithViewControllerClasses:(NSArray<Class> *)classes andTheirTitles:(NSArray<NSString *> *)titles {
    if (self = [super init]) {
        NSParameterAssert(classes.count == titles.count);
        _viewControllerClasses = [NSArray arrayWithArray:classes];
        _titles = [NSArray arrayWithArray:titles];

        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self setup];
    }
    return self;
}

- (instancetype)init {
    if (self = [super init]) {
        [self setup];
    }
    return self;
}

- (void)setCachePolicy:(WMPageControllerCachePolicy)cachePolicy {
    _cachePolicy = cachePolicy;
    self.memCache.countLimit = _cachePolicy;
}

- (void)setItemsMargins:(NSArray<NSNumber *> *)itemsMargins {
    NSParameterAssert(itemsMargins.count == self.viewControllerClasses.count + 1);
    _itemsMargins = itemsMargins;
}

- (void)setItemsWidths:(NSArray<NSNumber *> *)itemsWidths {
    NSParameterAssert(itemsWidths.count == self.titles.count);
    _itemsWidths = [itemsWidths copy];
}

- (void)setSelectIndex:(int)selectIndex {
    _selectIndex = selectIndex;
    if (self.menuView) {
        [self.menuView selectItemAtIndex:selectIndex];
    }
}

- (void)setViewFrame:(CGRect)viewFrame {
    _viewFrame = viewFrame;
    if (self.menuView) {
        [self viewDidLayoutSubviews];
    }
}

- (void)reloadData {
    [self clearDatas];
    [self resetScrollView];
    [self.memCache removeAllObjects];
    [self viewDidLayoutSubviews];
    [self resetMenuView];
}

- (void)updateTitle:(NSString *)title atIndex:(NSInteger)index {
    [self.menuView updateTitle:title atIndex:index andWidth:NO];
}

- (void)updateTitle:(NSString *)title andWidth:(CGFloat)width atIndex:(NSInteger)index {
    if (self.itemsWidths && index < self.itemsWidths.count) {
        NSMutableArray *mutableWidths = [NSMutableArray arrayWithArray:self.itemsWidths];
        mutableWidths[index] = @(width);
        self.itemsWidths = [mutableWidths copy];
    } else {
        NSMutableArray *mutableWidths = [NSMutableArray array];
        for (int i = 0; i < self.titles.count; i++) {
            CGFloat itemWidth = (i == index) ? width : self.menuItemWidth;
            [mutableWidths addObject:@(itemWidth)];
        }
        self.itemsWidths = [mutableWidths copy];
    }
    [self.menuView updateTitle:title atIndex:index andWidth:YES];
}

#pragma mark - Private Methods
- (void)resetScrollView {
    if (self.scrollView) {
        [self.scrollView removeFromSuperview];
    }
    [self addScrollView];
    [self addViewControllerAtIndex:self.selectIndex];
    self.currentViewController = self.displayVC[@(self.selectIndex)];
}

- (void)clearDatas {
    _hasInited = NO;
    NSArray *displayingViewControllers = self.displayVC.allValues;
    for (UIViewController *vc in displayingViewControllers) {
        [vc.view removeFromSuperview];
        [vc willMoveToParentViewController:nil];
        [vc removeFromParentViewController];
    }
    self.memoryWarningCount = 0;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(growCachePolicyAfterMemoryWarning) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(growCachePolicyToHigh) object:nil];
    self.currentViewController = nil;
    [self.posRecords removeAllObjects];
    [self.displayVC removeAllObjects];
}

// 当子控制器init完成时发送通知
- (void)postAddToSuperViewNotificationWithIndex:(int)index {
    if (!self.postNotification) { return; }
    NSDictionary *info = @{
                           @"index":@(index),
                           @"title":self.titles[index]
                           };
    [[NSNotificationCenter defaultCenter] postNotificationName:WMControllerDidAddToSuperViewNotification
                                                        object:info];
}

// 当子控制器完全展示在user面前时发送通知
- (void)postFullyDisplayedNotificationWithCurrentIndex:(int)index {
    if (!self.postNotification) { return; }
    NSDictionary *info = @{
                           @"index":@(index),
                           @"title":self.titles[index]
                           };
    [[NSNotificationCenter defaultCenter] postNotificationName:WMControllerDidFullyDisplayedNotification
                                                        object:info];
}

// 初始化一些参数，在init中调用
- (void)setup {
    _titleSizeSelected  = WMTitleSizeSelected;
    _titleColorSelected = WMTitleColorSelected;
    _titleSizeNormal    = WMTitleSizeNormal;
    _titleColorNormal   = WMTitleColorNormal;
    
    _menuBGColor   = WMMenuBGColor;
    _menuHeight    = WMMenuHeight;
    _menuItemWidth = WMMenuItemWidth;
    
    _memCache = [[NSCache alloc] init];
    
    self.automaticallyAdjustsScrollViewInsets = NO;
}

// 包括宽高，子控制器视图 frame
- (void)calculateSize {
    if (CGRectEqualToRect(self.viewFrame, CGRectZero)) {
        _viewWidth = self.view.frame.size.width;
        _viewHeight = self.view.frame.size.height - self.menuHeight - self.menuViewBottom;
    } else {
        _viewWidth = self.viewFrame.size.width;
        _viewHeight = self.viewFrame.size.height - self.menuHeight - self.menuViewBottom;
    }
    if (self.showOnNavigationBar && self.navigationController.navigationBar) {
        _viewHeight += self.menuHeight;
    }
    _viewX = self.viewFrame.origin.x;
    _viewY = self.viewFrame.origin.y;
    // 重新计算各个控制器视图的宽高
    _childViewFrames = [NSMutableArray array];
    for (int i = 0; i < self.viewControllerClasses.count; i++) {
        CGRect frame = CGRectMake(i*_viewWidth, 0, _viewWidth, _viewHeight);
        [_childViewFrames addObject:[NSValue valueWithCGRect:frame]];
    }
}

- (void)addScrollView {
    WMScrollView *scrollView = [[WMScrollView alloc] init];
    scrollView.scrollsToTop = NO;
    scrollView.pagingEnabled = YES;
    scrollView.backgroundColor = [UIColor whiteColor];
    scrollView.delegate = self;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.bounces = self.bounces;
    scrollView.otherGestureRecognizerSimultaneously = self.otherGestureRecognizerSimultaneously;
    [self.view addSubview:scrollView];
    self.scrollView = scrollView;
}

- (void)addMenuView {
    CGRect frame = CGRectMake(_viewX, _viewY, _viewWidth, self.menuHeight);
    WMMenuView *menuView = [[WMMenuView alloc] initWithFrame:frame];
    menuView.titles = self.titles;
    menuView.backgroundColor = self.menuBGColor;
    menuView.delegate = self;
    menuView.style = self.menuViewStyle;
    menuView.progressHeight = self.progressHeight;
    if (self.titleFontName) {
        menuView.fontName = self.titleFontName;
    }
    if (self.progressColor) {
        menuView.lineColor = self.progressColor;
    }
    if (self.showOnNavigationBar && self.navigationController.navigationBar) {
        self.navigationItem.titleView = menuView;
    } else {
        [self.view addSubview:menuView];
    }
    self.menuView = menuView;
    // 如果设置了初始选择的序号，那么选中该item
    if (self.selectIndex != 0) {
        [self.menuView selectItemAtIndex:self.selectIndex];
    }
}

- (void)layoutChildViewControllers {
    int currentPage = (int)self.scrollView.contentOffset.x / _viewWidth;
    int start = currentPage == 0 ? currentPage : (currentPage - 1);
    int end = (currentPage == self.viewControllerClasses.count - 1) ? currentPage : (currentPage + 1);
    for (int i = start; i <= end; i++) {
        CGRect frame = [self.childViewFrames[i] CGRectValue];
        UIViewController *vc = [self.displayVC objectForKey:@(i)];
        if ([self isInScreen:frame]) {
            if (vc == nil) {
                // 先从 cache 中取
                vc = [self.memCache objectForKey:@(i)];
                if (vc) {
                    // cache 中存在，添加到 scrollView 上，并放入display
                    [self addCachedViewController:vc atIndex:i];
                } else {
                    // cache 中也不存在，创建并添加到display
                    [self addViewControllerAtIndex:i];
                }
                [self postAddToSuperViewNotificationWithIndex:i];
            }
        } else {
            if (vc) {
                // vc不在视野中且存在，移除他
                [self removeViewController:vc atIndex:i];
            }
        }
    }
}

- (void)removeSuperfluousViewControllersIfNeeded {
    [self.displayVC enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull key, UIViewController * _Nonnull vc, BOOL * _Nonnull stop) {
        NSInteger index = key.integerValue;
        CGRect frame = [self.childViewFrames[index] CGRectValue];
        if (![self isInScreen:frame]) {
            [self removeViewController:vc atIndex:index];
        }
    }];
}

- (void)addCachedViewController:(UIViewController *)viewController atIndex:(NSInteger)index {
    [self addChildViewController:viewController];
    viewController.view.frame = [self.childViewFrames[index] CGRectValue];
    [viewController didMoveToParentViewController:self];
    [self.scrollView addSubview:viewController.view];
    [self.displayVC setObject:viewController forKey:@(index)];
}

// 添加子控制器
- (void)addViewControllerAtIndex:(int)index {
    Class vcClass = self.viewControllerClasses[index];
    UIViewController *viewController = [[vcClass alloc] init];
    if (self.values.count == self.viewControllerClasses.count && self.keys.count == self.viewControllerClasses.count) {
        [viewController setValue:self.values[index] forKey:self.keys[index]];
    }
    [self addChildViewController:viewController];
    viewController.view.frame = [self.childViewFrames[index] CGRectValue];
    [viewController didMoveToParentViewController:self];
    [self.scrollView addSubview:viewController.view];
    [self.displayVC setObject:viewController forKey:@(index)];
    
    [self backToPositionIfNeeded:viewController atIndex:index];
}

// 移除控制器，且从display中移除
- (void)removeViewController:(UIViewController *)viewController atIndex:(NSInteger)index {
    [self rememberPositionIfNeeded:viewController atIndex:index];
    [viewController.view removeFromSuperview];
    [viewController willMoveToParentViewController:nil];
    [viewController removeFromParentViewController];
    [self.displayVC removeObjectForKey:@(index)];
    
    // 放入缓存
    if (![self.memCache objectForKey:@(index)]) {
        [self.memCache setObject:viewController forKey:@(index)];
    }
}

- (void)backToPositionIfNeeded:(UIViewController *)controller atIndex:(NSInteger)index {
#pragma clang diagnostic push
#pragma clang diagnostic ignored"-Wdeprecated-declarations"
    if (!self.rememberLocation) return;
#pragma clang diagnostic pop
    if ([self.memCache objectForKey:@(index)]) return;
    UIScrollView *scrollView = [self isKindOfScrollViewController:controller];
    if (scrollView) {
        NSValue *pointValue = self.posRecords[@(index)];
        if (pointValue) {
            CGPoint pos = [pointValue CGPointValue];
            // 奇怪的现象，我发现 collectionView 的 contentSize 是 {0, 0};
            [scrollView setContentOffset:pos];
        }
    }
}

- (void)rememberPositionIfNeeded:(UIViewController *)controller atIndex:(NSInteger)index {
#pragma clang diagnostic push
#pragma clang diagnostic ignored"-Wdeprecated-declarations"
    if (!self.rememberLocation) return;
#pragma clang diagnostic pop
    UIScrollView *scrollView = [self isKindOfScrollViewController:controller];
    if (scrollView) {
        CGPoint pos = scrollView.contentOffset;
        self.posRecords[@(index)] = [NSValue valueWithCGPoint:pos];
    }
}

- (UIScrollView *)isKindOfScrollViewController:(UIViewController *)controller {
    UIScrollView *scrollView = nil;
    if ([controller.view isKindOfClass:[UIScrollView class]]) {
        // Controller的view是scrollView的子类(UITableViewController/UIViewController替换view为scrollView)
        scrollView = (UIScrollView *)controller.view;
    } else if (controller.view.subviews.count >= 1) {
        // Controller的view的subViews[0]存在且是scrollView的子类，并且frame等与view得frame(UICollectionViewController/UIViewController添加UIScrollView)
        UIView *view = controller.view.subviews[0];
        if ([view isKindOfClass:[UIScrollView class]]) {
            scrollView = (UIScrollView *)view;
        }
    }
    return scrollView;
}

- (BOOL)isInScreen:(CGRect)frame {
    CGFloat x = frame.origin.x;
    CGFloat ScreenWidth = self.scrollView.frame.size.width;
    
    CGFloat contentOffsetX = self.scrollView.contentOffset.x;
    if (CGRectGetMaxX(frame) > contentOffsetX && x-contentOffsetX < ScreenWidth) {
        return YES;
    } else {
        return NO;
    }
}

- (void)resetMenuView {
    WMMenuView *oldMenuView = self.menuView;
    [self addMenuView];
    [oldMenuView removeFromSuperview];
}

- (void)growCachePolicyAfterMemoryWarning {
    self.cachePolicy = WMPageControllerCachePolicyBalanced;
    [self performSelector:@selector(growCachePolicyToHigh) withObject:nil afterDelay:2.0 inModes:@[NSRunLoopCommonModes]];
}

- (void)growCachePolicyToHigh {
    self.cachePolicy = WMPageControllerCachePolicyHigh;
}

#pragma mark - Adjust Frame
- (void)adjustScrollViewFrame {
    // While rotate at last page, set scroll frame will call `-scrollViewDidScroll:` delegate
    // It's not my expectation, so I use `_shouldNotScroll` to lock it.
    // Wait for a better solution.
    _shouldNotScroll = YES;
    CGRect scrollFrame = CGRectMake(_viewX, _viewY + self.menuHeight + self.menuViewBottom, _viewWidth, _viewHeight);
    scrollFrame.origin.y -= self.showOnNavigationBar && self.navigationController.navigationBar ? self.menuHeight : 0;
    self.scrollView.frame = scrollFrame;
    self.scrollView.contentSize = CGSizeMake(self.titles.count * _viewWidth, 0);
    [self.scrollView setContentOffset:CGPointMake(self.selectIndex * _viewWidth, 0)];
    _shouldNotScroll = NO;
}

- (void)adjustMenuViewFrame {
    // 根据是否在导航栏上展示调整frame
    CGFloat menuHeight = self.menuHeight;
    __block CGFloat menuX = _viewX;
    __block CGFloat rightWidth = 0;
    if (self.showOnNavigationBar && self.navigationController.navigationBar) {
        [self.navigationController.navigationBar.subviews enumerateObjectsUsingBlock:^(__kindof UIView * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ([obj isKindOfClass:NSClassFromString(@"UINavigationItemView")] || [obj isKindOfClass:NSClassFromString(@"UINavigationButton")]) {
                CGFloat x = CGRectGetMinX(obj.frame);
                if (x < _viewWidth / 2) {
                    CGFloat leftWidth = CGRectGetMaxX(obj.frame) + kWMMarginToNavigationItem;
                    menuX = menuX > leftWidth ? menuX : leftWidth;
                } else {
                    rightWidth = (_viewWidth - CGRectGetMinX(obj.frame)) + kWMMarginToNavigationItem;
                }
            }
        }];
        CGFloat navHeight = self.navigationController.navigationBar.frame.size.height;
        menuHeight = self.menuHeight > navHeight ? navHeight : self.menuHeight;
    }
    CGFloat menuWidth = _viewWidth - menuX - rightWidth;
    self.menuView.frame = CGRectMake(menuX, _viewY, menuWidth, menuHeight);
    [self.menuView resetFrames];
}

#pragma mark - Life Cycle
- (void)viewDidLoad {
    [super viewDidLoad];

    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.view.backgroundColor = [UIColor whiteColor];
    
    if (!self.viewControllerClasses.count) return;
    
    [self addScrollView];
    
    [self addViewControllerAtIndex:self.selectIndex];
    self.currentViewController = self.displayVC[@(self.selectIndex)];
    
    [self addMenuView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    if (!self.viewControllerClasses) return;
    
    CGFloat oldSuperviewHeight = _superviewHeight;
    _superviewHeight = self.view.frame.size.height;

    if (_hasInited && _superviewHeight == oldSuperviewHeight) return;

    // 计算宽高及子控制器的视图frame
    [self calculateSize];
    
    [self adjustScrollViewFrame];
    
    [self adjustMenuViewFrame];
    
    [self removeSuperfluousViewControllersIfNeeded];
    self.currentViewController.view.frame = [self.childViewFrames[self.selectIndex] CGRectValue];
    _hasInited = YES;
    [self.view layoutIfNeeded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self postFullyDisplayedNotificationWithCurrentIndex:self.selectIndex];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
    self.memoryWarningCount++;
    self.cachePolicy = WMPageControllerCachePolicyLowMemory;
    // 取消正在增长的 cache 操作
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(growCachePolicyAfterMemoryWarning) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(growCachePolicyToHigh) object:nil];
    
    [self.memCache removeAllObjects];
    [self.posRecords removeAllObjects];
    self.posRecords = nil;
    
    // 如果收到内存警告次数小于 3，一段时间后切换到模式 Balanced
    if (self.memoryWarningCount < 3) {
        [self performSelector:@selector(growCachePolicyAfterMemoryWarning) withObject:nil afterDelay:3.0 inModes:@[NSRunLoopCommonModes]];
    }
}

#pragma mark - UIScrollView Delegate
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (_shouldNotScroll) { return; }
    
    [self layoutChildViewControllers];
    if (_animate) {
        CGFloat contentOffsetX = scrollView.contentOffset.x;
        if (contentOffsetX < 0) {
            contentOffsetX = 0;
        }
        if (contentOffsetX > scrollView.contentSize.width - _viewWidth) {
            contentOffsetX = scrollView.contentSize.width - _viewWidth;
        }
        CGFloat rate = contentOffsetX / _viewWidth;
        [self.menuView slideMenuAtProgress:rate];
    }
    
    // fix scrollView.contentOffset.y -> (-20) unexpectedly.
    if (scrollView.contentOffset.y == 0) { return; }
    CGPoint contentOffset = scrollView.contentOffset;
    contentOffset.y = 0.0;
    scrollView.contentOffset = contentOffset;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    _animate = YES;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    _selectIndex = (int)scrollView.contentOffset.x / _viewWidth;
    [self removeSuperfluousViewControllersIfNeeded];
    self.currentViewController = self.displayVC[@(self.selectIndex)];
    [self postFullyDisplayedNotificationWithCurrentIndex:self.selectIndex];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    self.currentViewController = self.displayVC[@(self.selectIndex)];
    [self removeSuperfluousViewControllersIfNeeded];
    [self postFullyDisplayedNotificationWithCurrentIndex:self.selectIndex];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        CGFloat rate = _targetX / _viewWidth;
        [self removeSuperfluousViewControllersIfNeeded];
        [self.menuView slideMenuAtProgress:rate];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    _targetX = targetContentOffset->x;
}

#pragma mark - WMMenuView Delegate
- (void)menuView:(WMMenuView *)menu didSelesctedIndex:(NSInteger)index currentIndex:(NSInteger)currentIndex {
    NSInteger gap = (NSInteger)labs(index - currentIndex);
    _selectIndex = (int)index;
    _animate = NO;
    CGPoint targetP = CGPointMake(_viewWidth*index, 0);
    
    [self.scrollView setContentOffset:targetP animated:gap > 1 ? NO : self.pageAnimatable];
    if (gap > 1 || !self.pageAnimatable) {
        // 由于不触发 -scrollViewDidScroll: 手动处理控制器
        UIViewController *currentViewController = self.displayVC[@(currentIndex)];
        // 最好判断一下，因为在做某个项目时，currentViewController = nil
        if (currentViewController) {
            [self removeViewController:currentViewController atIndex:currentIndex];
        }
        [self layoutChildViewControllers];
        self.currentViewController = self.displayVC[@(self.selectIndex)];
        [self postFullyDisplayedNotificationWithCurrentIndex:(int)index];
    }
}

- (CGFloat)menuView:(WMMenuView *)menu widthForItemAtIndex:(NSInteger)index {
    if (self.itemsWidths.count == self.viewControllerClasses.count) {
        return [self.itemsWidths[index] floatValue];
    }
    return self.menuItemWidth;
}

- (CGFloat)menuView:(WMMenuView *)menu itemMarginAtIndex:(NSInteger)index {
    if (self.itemsMargins.count == self.viewControllerClasses.count + 1) {
        return [self.itemsMargins[index] floatValue];
    }
    return self.itemMargin;
}

- (CGFloat)menuView:(WMMenuView *)menu titleSizeForState:(WMMenuItemState)state {
    switch (state) {
        case WMMenuItemStateSelected: {
            return self.titleSizeSelected;
            break;
        }
        case WMMenuItemStateNormal: {
            return self.titleSizeNormal;
            break;
        }
    }
}

- (UIColor *)menuView:(WMMenuView *)menu titleColorForState:(WMMenuItemState)state {
    switch (state) {
        case WMMenuItemStateSelected: {
            return self.titleColorSelected;
            break;
        }
        case WMMenuItemStateNormal: {
            return self.titleColorNormal;
            break;
        }
    }
}

@end
