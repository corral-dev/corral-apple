import CoreGraphics

/// 全局间距 token，与工作区 iOS 间距规范一致。
enum Space {
    /// 4pt — 微调
    static let xs: CGFloat = 4
    /// 8pt — 主节奏
    static let sm: CGFloat = 8
    /// 12pt — 中等
    static let md: CGFloat = 12
    /// 16pt — 常规外边距
    static let base: CGFloat = 16
    /// 20pt — 宽屏外边距
    static let lg: CGFloat = 20
    /// 24pt — section 间距
    static let xl: CGFloat = 24
    /// 32pt — 松散 section
    static let xxl: CGFloat = 32
}

/// 触控与视觉尺寸。
enum TouchTarget {
    static let minimum: CGFloat = 44
    static let iconVisual: CGFloat = 24
    /// 关注状态圆点
    static let attentionDot: CGFloat = 8
    static let headerStateDot: CGFloat = 6
}

/// 圆角 token。
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let pill: CGFloat = 999
    /// 聊天气泡主体圆角（iMessage 式不对称大圆角）
    static let bubble: CGFloat = 18
    /// 气泡靠发言方向一侧的收尾小角
    static let bubbleTail: CGFloat = 5
    /// Floating composer card. Larger than message bubbles so the detached
    /// input reads as a single surface, not another bubble.
    static let composer: CGFloat = 24
}
