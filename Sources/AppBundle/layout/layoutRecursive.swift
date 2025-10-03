import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(
            rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect,
            LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(
        _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext
    ) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
        case .workspace(let workspace):
            lastAppliedLayoutPhysicalRect = physicalRect
            lastAppliedLayoutVirtualRect = virtual
            try await workspace.rootTilingContainer.layoutRecursive(
                point, width: width, height: height, virtual: virtual, context)
            for window in workspace.children.filterIsInstance(of: Window.self) {
                window.lastAppliedLayoutPhysicalRect = nil
                window.lastAppliedLayoutVirtualRect = nil
                try await window.layoutFloatingWindow(context)
            }
        case .window(let window):
            if window.windowId != currentlyManipulatedWithMouseWindowId {
                lastAppliedLayoutVirtualRect = virtual
                if window.isFullscreen
                    && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive
                {
                    lastAppliedLayoutPhysicalRect = nil
                    window.layoutFullscreen(context)
                } else {
                    lastAppliedLayoutPhysicalRect = physicalRect
                    window.isFullscreen = false
                    window.setAxFrame(point, CGSize(width: width, height: height))
                }
            }
        case .tilingContainer(let container):
            lastAppliedLayoutPhysicalRect = physicalRect
            lastAppliedLayoutVirtualRect = virtual
            switch container.layout {
            case .tiles:
                try await container.layoutScrolling(
                    point, width: width, height: height, virtual: virtual, context)
            case .accordion:
                try await container.layoutAccordion(
                    point, width: width, height: height, virtual: virtual, context)
            }
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
            .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return  // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let currentMonitor = try await getCenter()?.monitorApproximation  // Probably not idempotent
        if let currentMonitor, let windowTopLeftCorner = try await getAxTopLeftCorner(),
            workspace != currentMonitor.activeWorkspace
        {
            let xProportion =
                (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX)
                / currentMonitor.visibleRect.width
            let yProportion =
                (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY)
                / currentMonitor.visibleRect.height

            let moveTo = workspace.workspaceMonitor
            setAxTopLeftCorner(
                CGPoint(
                    x: moveTo.visibleRect.topLeftX + xProportion * moveTo.visibleRect.width,
                    y: moveTo.visibleRect.topLeftY + yProportion * moveTo.visibleRect.height,
                ))
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect =
            noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(
            monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(
        _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext
    ) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard
            let delta =
                ((orientation == .h ? width : height)
                - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
                .div(children.count)
        else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint =
                orientation == .h
                ? virtualPoint.addingXOffset(child.hWeight)
                : virtualPoint.addingYOffset(child.vWeight)
            point =
                orientation == .h
                ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutScrolling(
        _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext
    ) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        let topLeftCorner = virtual.topLeftCorner
        let bottomRightCorner = virtual.bottomRightCorner
        let layoutPoint = point
        var point = point

        let gap = context.resolvedGaps.inner.get(orientation).toDouble()

        // Initial size, TODO Set this in settings
        let defaultSize = ((orientation == .h ? width : height) * 0.4)

        var mruChildren = mostRecentChildren
        let sizes = children.map { child in
            (orientation == .h ? child.hWeight : child.vWeight) + defaultSize
        }
        print("sizes: \(sizes)")

        // let lastIndex = children.indices.last
        var start = children.count
        var end = 0
        var offset: CGFloat = 0.0

        var item = mruChildren.next()
        while item != nil {
            // TODO IMPORTANT navigate from: itemIndex < start ? start - 1 ... itemIndex : itemIndex > end ? end + 1 ... itemIndex
            let itemIndex = item?.ownIndex ?? 0
            let size = sizes[min(itemIndex, start)...max(itemIndex, end)].reduce(0, +)
            start = min(start, itemIndex)
            end = max(end, itemIndex)
            if size >= (orientation == .h ? width : height) {
                if itemIndex < mruIndex {
                    offset = (orientation == .h ? width : height) - size
                }
                print(
                    "itemIndex: \(itemIndex) size: \(size) width: \(width) height: \(height) overflow!"
                )
                break
            }
            print("itemIndex: \(itemIndex) size: \(size)")

            item = mruChildren.next()
        }

        print("offset: \(offset) start: \(start), end: \(end)")

        let padding = CGFloat(config.accordionPadding)

        var virtualTopLeftCorner = topLeftCorner

        // for index in stride(from: start, through: end, by: 1) {
        for index in stride(from: 0, through: children.count - 1, by: 1) {
            print("Adding visible item \(index)")
            let child = children[index]
            let size = sizes[index]

            if index < start {
                virtualTopLeftCorner =
                    orientation == .h
                    ? topLeftCorner.addingXOffset(-size + 1)  // gap or -size + 1
                    : topLeftCorner.addingYOffset(-size + 1)  // gap or -size + 1
                point =
                    orientation == .h
                    ? layoutPoint.addingXOffset(-size + 1)  // gap or -size + 1
                    : layoutPoint.addingYOffset(-size + 1)  // gap or -size + 1
            }
            if index >= start && index <= end {
                if index == start {
                    virtualTopLeftCorner = topLeftCorner
                    point = layoutPoint
                }
                virtualTopLeftCorner =
                    orientation == .h
                    ? virtualTopLeftCorner.addingXOffset(offset)
                    : virtualTopLeftCorner.addingYOffset(offset)
                point =
                    orientation == .h
                    ? point.addingXOffset(offset) : point.addingYOffset(offset)
                offset = size
            }
            if index > end {
                virtualTopLeftCorner =
                    orientation == .h
                    ? bottomRightCorner.addingXOffset(-1)  // -1 or -size
                    : bottomRightCorner.addingYOffset(-1)  // -1 or -size
                point =
                    orientation == .h
                    ? layoutPoint.addingXOffset(width - 1)  // -1 or -size
                    : layoutPoint.addingYOffset(height - 1)  // -1 or -size
            }

            try await child.layoutRecursive(
                point.addingOffset(orientation, gap / 2),
                width: orientation == .h ? size - gap : width,
                height: orientation == .v ? size - gap : height,
                virtual: Rect(
                    topLeftX: virtualTopLeftCorner.x,
                    topLeftY: virtualTopLeftCorner.y,
                    width: orientation == .h ? size : width,
                    height: orientation == .v ? size : height,
                ),
                context,
            )
        }
    }

    @MainActor
    fileprivate func layoutAccordion(
        _ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext
    ) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) =
                switch index {
                case 0 where children.count == 1: (0, 0)
                case 0: (0, padding)
                case children.indices.last: (padding, 0)
                case mruIndex - 1: (0, 2 * padding)
                case mruIndex + 1: (2 * padding, 0)
                default: (padding, padding)
                }
            switch orientation {
            case .h:
                try await child.layoutRecursive(
                    point + CGPoint(x: lPadding, y: 0),
                    width: width - rPadding - lPadding,
                    height: height,
                    virtual: virtual,
                    context,
                )
            case .v:
                try await child.layoutRecursive(
                    point + CGPoint(x: 0, y: lPadding),
                    width: width,
                    height: height - lPadding - rPadding,
                    virtual: virtual,
                    context,
                )
            }
        }
    }
}
