public struct ResizeCmdArgs: CmdArgs {
    public let rawArgs: EquatableNoop<[String]>
    fileprivate init(rawArgs: [String]) { self.rawArgs = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .resize,
        allowInConfig: true,
        help: resize_help_generated,
        options: [
            "--window-id": optionalWindowIdFlag()
        ],
        arguments: [
            newArgParser(
                \.dimension, parseDimension,
                mandatoryArgPlaceholder: "(smart|smart-opposite|width|height)"),
            newArgParser(\.units, parseUnits, mandatoryArgPlaceholder: "[+|-]<number>|predefined"),
        ],
    )

    public var dimension: Lateinit<ResizeCmdArgs.Dimension> = .uninitialized
    public var units: Lateinit<ResizeCmdArgs.Units> = .uninitialized
    /*conforms*/ public var windowId: UInt32?
    /*conforms*/ public var workspaceName: WorkspaceName?

    public init(
        rawArgs: [String],
        dimension: Dimension,
        units: Units
    ) {
        self.rawArgs = .init(rawArgs)
        self.dimension = .initialized(dimension)
        self.units = .initialized(units)
    }

    public enum Dimension: String, CaseIterable, Equatable, Sendable {
        case width, height, smart
        case smartOpposite = "smart-opposite"
    }

    public enum Units: Equatable, Sendable {
        case set(UInt)
        case add(UInt)
        case subtract(UInt)
        case predefined([Float])
    }
}

public func parseResizeCmdArgs(_ args: [String]) -> ParsedCmd<ResizeCmdArgs> {
    parseSpecificCmdArgs(ResizeCmdArgs(rawArgs: args), args)
}

private func parseDimension(arg: String, nextArgs: inout [String]) -> Parsed<
    ResizeCmdArgs.Dimension
> {
    parseEnum(arg, ResizeCmdArgs.Dimension.self)
}

private func parseUnits(arg: String, nextArgs: inout [String]) -> Parsed<ResizeCmdArgs.Units> {
    if let number = UInt(arg.removePrefix("+").removePrefix("-")) {
        switch true {
        case arg.starts(with: "+"): .success(.add(number))
        case arg.starts(with: "-"): .success(.subtract(number))
        default: .success(.set(number))
        }
    } else if arg == "predefined" {
        .success(.predefined([0.3333, 0.5, 0.6667, 1.0]))  // TODO make configurable (and also add hardcoded pixel size support?)
    } else {
        .failure("<number> argument must be a number")
    }
}
