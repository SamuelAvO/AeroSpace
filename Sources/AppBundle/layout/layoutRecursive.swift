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
                try await container.layoutTiles(
                    point, width: width, height: height, virtual: virtual, context)
            case .accordion:
                try await container.layoutAccordion(
                    point, width: width, height: height, virtual: virtual, context)
            case .scrolling:
                try await container.layoutScrolling(
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
        let orientationSize = (orientation == .h ? width : height)

        let gap = context.resolvedGaps.inner.get(orientation).toDouble()
        var padding: CGFloat = CGFloat(config.accordionPadding)

        // Initial size, TODO Set this in settings
        let defaultSize =
            (orientationSize > 2400
                ? (orientationSize - padding) * (1 / 3)
                : (orientationSize - padding) * 0.5)

        var mruChildren = mostRecentChildren

        for (_, child) in children.enumerated() {
            let weight = child.getWeight(orientation)
            if weight <= 1 {
                child.setWeight(orientation, defaultSize)
            } else if weight > orientationSize {
                child.setWeight(orientation, orientationSize)
            }
        }

        let sizes = children.map { child in
            (orientation == .h
                ? min(child.hWeight, width)
                : min(child.vWeight, height))
        }

        var start = children.count - 1
        var end = 0
        var offset: CGFloat = 0.0

        var item = mruChildren.next()
        var indexes: [Int] = [0, children.count - 1]
        var index = item?.ownIndex ?? indexes.first ?? -1
        while index >= 0 {
            // TODO IMPORTANT navigate from: itemIndex < start ? start - 1 ... itemIndex : itemIndex > end ? end + 1 ... itemIndex
            indexes.remove(element: index)
            let size = sizes[min(index, start)...max(index, end)].reduce(0, +)

            start = min(start, index)
            end = max(end, index)
            if size >= orientationSize - 1 {
                if index < mruIndex {
                    // align to the right, half show this window by setting the offset
                    offset = orientationSize - size
                    if end < children.count - 1 && start != end
                        && sizes[end] + padding <= orientationSize
                    {
                        offset -= padding
                    }
                } else {
                    // Left align, no offset needed
                    offset = 0
                    if start > 0 && start != end && padding > 0
                        && sizes[start] + padding <= orientationSize
                    {
                        // More items to the left, show one more item with padding size
                        offset = 0 - sizes[start - 1] + padding
                        start = start - 1
                    }
                }
                break
            } else if size < orientationSize {
                // Center align when not filling all space
                offset = (orientationSize - size) / 2
            }

            item = mruChildren.next()
            index = item?.ownIndex ?? indexes.first ?? -1
        }

        var virtualTopLeftCorner = topLeftCorner

        for index in stride(from: 0, through: children.count - 1, by: 1) {
            let child = children[index]
            let size = sizes[index]
            let maxOverflowStart = monitors.count > 1 ? CGFloat(0) : size  // size / 3
            let maxOverflowEnd = monitors.count > 1 ? CGFloat(0) : size  // size / 3

            if index < start {
                virtualTopLeftCorner =
                    orientation == .h
                    ? topLeftCorner.addingXOffset(-size)  // gap or -size + 1
                    : topLeftCorner.addingYOffset(-size)  // gap or -size + 1
                point =
                    orientation == .h
                    ? layoutPoint.addingXOffset(-size)  // gap or -size + 1
                    : layoutPoint.addingYOffset(-size)  // gap or -size + 1
            }
            if index >= start {
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
            var lPadding: CGFloat = gap / 2
            var rPadding: CGFloat = gap / 2
            padding = gap / 2  // enable this to disable padding for scrolling layout

            if index == 0 {
                lPadding = 0
            } else if index == start {
                lPadding = padding
            }
            if index == children.count - 1 {
                rPadding = 0
            } else if index == end {
                rPadding = padding
            }

            try await child.layoutRecursive(
                CGPoint(
                    x: orientation == .v
                        ? point.x
                        : min(
                            max(point.x, layoutPoint.x - maxOverflowStart),
                            layoutPoint.x + width - size + maxOverflowEnd),
                    y: orientation == .h
                        ? point.y
                        : min(
                            max(point.y, layoutPoint.y - maxOverflowStart),
                            layoutPoint.y + height - size + maxOverflowEnd)
                ).addingOffset(orientation, lPadding),
                width: orientation == .h ? size - lPadding - rPadding : width,
                height: orientation == .v ? size - lPadding - rPadding : height,
                virtual: Rect(
                    topLeftX: min(
                        max(virtualTopLeftCorner.x, topLeftCorner.x - maxOverflowStart),
                        bottomRightCorner.x - size + maxOverflowEnd),
                    topLeftY: min(
                        max(virtualTopLeftCorner.y, topLeftCorner.y - maxOverflowStart),
                        bottomRightCorner.y - size + maxOverflowEnd),
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
