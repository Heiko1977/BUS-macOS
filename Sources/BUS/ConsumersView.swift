import AppKit
import SwiftUI

enum ConsumerGroupingMode: String, CaseIterable, Identifiable {
    case apps
    case processes
    var id: String { rawValue }
}

enum ConsumerFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case significant
    var id: String { rawValue }
}

enum ConsumerSortColumn: String, CaseIterable {
    case app
    case battery
    case share
    case cpu
    case io
    case wakeups
    case processCount
}

enum ConsumerSortDirection: String {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct FlattenedProcessRow: Identifiable {
    let app: AppEnergyRecord
    let process: ProcessEnergyRecord

    var id: String {
        "\(app.id)|\(process.id)"
    }
}

@MainActor
final class ConsumersViewState: ObservableObject {
    @Published var expandedAppIDs: Set<String> = []
    @Published var searchText = ""

    @Published var groupingMode: ConsumerGroupingMode {
        didSet {
            UserDefaults.standard.set(
                groupingMode.rawValue,
                forKey: "BUS.consumerGroupingMode"
            )
        }
    }

    @Published var filter: ConsumerFilter {
        didSet {
            UserDefaults.standard.set(
                filter.rawValue,
                forKey: "BUS.consumerFilter"
            )
        }
    }

    @Published var sortColumn: ConsumerSortColumn {
        didSet {
            UserDefaults.standard.set(
                sortColumn.rawValue,
                forKey: "BUS.consumerSortColumn"
            )
        }
    }

    @Published var sortDirection: ConsumerSortDirection {
        didSet {
            UserDefaults.standard.set(
                sortDirection.rawValue,
                forKey: "BUS.consumerSortDirection"
            )
        }
    }

    init() {
        let defaults = UserDefaults.standard
        groupingMode = ConsumerGroupingMode(
            rawValue: defaults.string(
                forKey: "BUS.consumerGroupingMode"
            ) ?? ""
        ) ?? .apps
        filter = ConsumerFilter(
            rawValue: defaults.string(
                forKey: "BUS.consumerFilter"
            ) ?? ""
        ) ?? .all
        sortColumn = ConsumerSortColumn(
            rawValue: defaults.string(
                forKey: "BUS.consumerSortColumn"
            ) ?? ""
        ) ?? .battery
        sortDirection = ConsumerSortDirection(
            rawValue: defaults.string(
                forKey: "BUS.consumerSortDirection"
            ) ?? ""
        ) ?? .descending
    }

    func toggle(_ id: String) {
        if expandedAppIDs.contains(id) {
            expandedAppIDs.remove(id)
        } else {
            expandedAppIDs.insert(id)
        }
    }

    func selectSort(_ column: ConsumerSortColumn) {
        if sortColumn == column {
            sortDirection.toggle()
        } else {
            sortColumn = column
            sortDirection = column == .app ? .ascending : .descending
        }
    }
}

struct ConsumersView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    @StateObject private var state = ConsumersViewState()

    private let batteryWidth: CGFloat = 150
    private let shareWidth: CGFloat = 90
    private let cpuWidth: CGFloat = 72
    private let ioWidth: CGFloat = 96
    private let wakeWidth: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            columnHeader

            ScrollView {
                VStack(spacing: 0) {
                    if filteredApps.isEmpty {
                        ContentUnavailableView(
                            l.t("noData"),
                            systemImage: "bolt.slash",
                            description: Text(l.t("estimateInfo"))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                    } else {
                        LazyVStack(spacing: 8) {
                            if state.groupingMode == .apps {
                                ForEach(filteredApps) { app in
                                    appGroup(app)
                                }
                            } else {
                                ForEach(flattenedProcesses) { row in
                                    standaloneProcessRow(row.process, app: row.app)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    totals
                    footer
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(
            text: $state.searchText,
            placement: .toolbar,
            prompt: l.t("searchApps")
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l.t("consumers"))
                    .font(.system(size: 28, weight: .bold))
                Text(l.t("groupedProcessesInfo"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { monitor.exportCSV() } label: {
                Label(l.t("export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker(
                "",
                selection: Binding(
                    get: { state.groupingMode },
                    set: { newValue in
                        guard newValue != state.groupingMode else { return }
                        state.groupingMode = newValue
                    }
                )
            ) {
                Text(l.t("groupByApp")).tag(ConsumerGroupingMode.apps)
                Text(l.t("groupByProcess")).tag(ConsumerGroupingMode.processes)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            Picker(
                "",
                selection: Binding(
                    get: { state.filter },
                    set: { newValue in
                        guard newValue != state.filter else { return }
                        state.filter = newValue
                    }
                )
            ) {
                Text(l.t("showAll")).tag(ConsumerFilter.all)
                Text(l.t("showActive")).tag(ConsumerFilter.active)
                Text(l.t("showSignificant")).tag(ConsumerFilter.significant)
            }
            .frame(width: 180)

            Spacer()

            TextField(
                l.t("searchApps"),
                text: $state.searchText
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            sortHeader(
                title: l.t("appProcess"),
                column: .app,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            sortHeader(
                title: l.t("estimatedBattery"),
                column: .battery,
                alignment: .trailing
            )
            .frame(width: batteryWidth, alignment: .trailing)

            sortHeader(
                title: l.t("share"),
                column: .share,
                alignment: .trailing
            )
            .frame(width: shareWidth, alignment: .trailing)

            sortHeader(
                title: l.t("cpu"),
                column: .cpu,
                alignment: .trailing
            )
            .frame(width: cpuWidth, alignment: .trailing)

            sortHeader(
                title: l.t("disk"),
                column: .io,
                alignment: .trailing
            )
            .frame(width: ioWidth, alignment: .trailing)

            sortHeader(
                title: l.t("wakeups"),
                column: .wakeups,
                alignment: .trailing
            )
            .frame(width: wakeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
    }

    private func sortHeader(
        title: String,
        column: ConsumerSortColumn,
        alignment: Alignment
    ) -> some View {
        Button {
            state.selectSort(column)
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }

                Text(title)
                    .lineLimit(1)

                if state.sortColumn == column {
                    Image(
                        systemName: state.sortDirection == .ascending
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.caption2.bold())
                }

                if alignment == .leading {
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l.t("sortByColumn"))
    }

    @ViewBuilder
    private func appGroup(_ app: AppEnergyRecord) -> some View {
        let processes = sortedProcesses(for: app)
        let expanded = state.expandedAppIDs.contains(app.id)

        VStack(spacing: 0) {
            Button {
                if !processes.isEmpty {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.toggle(app.id)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(processes.isEmpty ? Color.clear : Color.secondary)
                        .frame(width: 14)

                    Image(nsImage: AppIconProvider.icon(for: app))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.headline)
                                .lineLimit(1)

                            if !processes.isEmpty {
                                Text("\(processes.count)")
                                    .font(.caption.bold())
                                    .monospacedDigit()
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        HStack(spacing: 5) {
                            if let id = app.bundleIdentifier {
                                Text(id)
                            }
                            if !processes.isEmpty {
                                Text("· \(processes.count) \(l.t(processes.count == 1 ? "process" : "processes"))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    batteryMetric(
                        percent: monitor.attributedBatteryPercent(for: app),
                        width: batteryWidth
                    )
                    metric(String(format: "%.1f %%", monitor.share(for: app) * 100), shareWidth)
                    metric(duration(app.cpuSeconds), cpuWidth)
                    metric(byteString(app.diskBytes), ioWidth)
                    metric(app.wakeups.formatted(), wakeWidth)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(processes.isEmpty ? Color.clear : Color.secondary)
                        .frame(width: 18)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().padding(.leading, 60)

                ForEach(processes) { process in
                    processRow(process, app: app)
                    if process.id != processes.last?.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }

    private func processRow(_ process: ProcessEnergyRecord, app: AppEnergyRecord) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 14)
            Image(systemName: "gearshape")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayProcessName(process, app: app))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if process.pid > 0 {
                        Text("PID \(process.pid)")
                    } else {
                        Text(l.t("historicalProcess"))
                    }
                    if let bundle = process.bundleIdentifier, bundle != app.bundleIdentifier {
                        Text(bundle).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            batteryMetric(
                percent: monitor.attributedBatteryPercent(for: process),
                width: batteryWidth,
                compact: true
            )
            metric(String(format: "%.1f %%", monitor.share(for: process, in: app) * 100), shareWidth, true)
            metric(duration(process.cpuSeconds), cpuWidth, true)
            metric(byteString(process.diskBytes), ioWidth, true)
            metric(process.wakeups.formatted(), wakeWidth, true)

            Color.clear.frame(width: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
    }

    private func standaloneProcessRow(
        _ process: ProcessEnergyRecord,
        app: AppEnergyRecord
    ) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconProvider.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayProcessName(process, app: app))
                    .font(.headline)
                    .lineLimit(1)
                Text("\(app.name) · \(process.pid > 0 ? "PID \(process.pid)" : l.t("historicalProcess"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            batteryMetric(percent: monitor.attributedBatteryPercent(for: process), width: batteryWidth)
            metric(String(format: "%.1f %%", monitor.share(for: process, in: app) * 100), shareWidth)
            metric(duration(process.cpuSeconds), cpuWidth)
            metric(byteString(process.diskBytes), ioWidth)
            metric(process.wakeups.formatted(), wakeWidth)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        }
    }

    private var totals: some View {
        HStack(spacing: 12) {
            Text(l.t("total"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            metric(String(format: "%.2f %%", totalBatteryPercent), batteryWidth)
            metric("100 %", shareWidth)
            metric(duration(filteredApps.reduce(0) { $0 + $1.cpuSeconds }), cpuWidth)
            metric(byteString(filteredApps.reduce(0) { $0 &+ $1.diskBytes }), ioWidth)
            metric(filteredApps.reduce(UInt64(0)) { $0 &+ $1.wakeups }.formatted(), wakeWidth)
            Color.clear.frame(width: 18)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
    }

    private var footer: some View {
        Label(l.t("estimateInfo"), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var filteredApps: [AppEnergyRecord] {
        let query = state.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let filtered = monitor.sortedRecords.filter { app in
            let matchesFilter: Bool
            switch state.filter {
            case .all:
                matchesFilter = true
            case .active:
                matchesFilter = Date().timeIntervalSince(app.lastSeen) < 300
            case .significant:
                matchesFilter = monitor.share(for: app) >= 0.01
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            if app.name.lowercased().contains(query) {
                return true
            }
            if app.bundleIdentifier?.lowercased().contains(query) == true {
                return true
            }
            return app.sortedProcesses.contains {
                $0.name.lowercased().contains(query)
                    || ($0.bundleIdentifier?.lowercased().contains(query) == true)
            }
        }

        return filtered.sorted(by: compareApps)
    }

    private var flattenedProcesses: [FlattenedProcessRow] {
        filteredApps
            .flatMap { app in
                sortedProcesses(for: app).map { process in
                    FlattenedProcessRow(app: app, process: process)
                }
            }
            .sorted(by: compareProcessRows)
    }

    private var totalBatteryPercent: Double {
        filteredApps.reduce(0) {
            $0 + monitor.attributedBatteryPercent(for: $1)
        }
    }

    private func compareApps(
        _ lhs: AppEnergyRecord,
        _ rhs: AppEnergyRecord
    ) -> Bool {
        let ascending = state.sortDirection == .ascending
        let result: ComparisonResult

        switch state.sortColumn {
        case .app:
            result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .battery:
            result = compare(
                monitor.attributedBatteryPercent(for: lhs),
                monitor.attributedBatteryPercent(for: rhs)
            )
        case .share:
            result = compare(
                monitor.share(for: lhs),
                monitor.share(for: rhs)
            )
        case .cpu:
            result = compare(lhs.cpuSeconds, rhs.cpuSeconds)
        case .io:
            result = compare(lhs.diskBytes, rhs.diskBytes)
        case .wakeups:
            result = compare(lhs.wakeups, rhs.wakeups)
        case .processCount:
            result = compare(
                lhs.sortedProcesses.count,
                rhs.sortedProcesses.count
            )
        }

        if result == .orderedSame {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
        }
        return ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func sortedProcesses(
        for app: AppEnergyRecord
    ) -> [ProcessEnergyRecord] {
        app.sortedProcesses.sorted { lhs, rhs in
            let ascending = state.sortDirection == .ascending
            let result: ComparisonResult

            switch state.sortColumn {
            case .app:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .battery:
                result = compare(
                    monitor.attributedBatteryPercent(for: lhs),
                    monitor.attributedBatteryPercent(for: rhs)
                )
            case .share:
                result = compare(
                    monitor.share(for: lhs, in: app),
                    monitor.share(for: rhs, in: app)
                )
            case .cpu:
                result = compare(lhs.cpuSeconds, rhs.cpuSeconds)
            case .io:
                result = compare(lhs.diskBytes, rhs.diskBytes)
            case .wakeups:
                result = compare(lhs.wakeups, rhs.wakeups)
            case .processCount:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            }

            if result == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
            return ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func compareProcessRows(
        _ lhs: FlattenedProcessRow,
        _ rhs: FlattenedProcessRow
    ) -> Bool {
        let ascending = state.sortDirection == .ascending
        let result: ComparisonResult

        switch state.sortColumn {
        case .app:
            result = lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name)
        case .battery:
            result = compare(
                monitor.attributedBatteryPercent(for: lhs.process),
                monitor.attributedBatteryPercent(for: rhs.process)
            )
        case .share:
            result = compare(
                monitor.share(for: lhs.process, in: lhs.app),
                monitor.share(for: rhs.process, in: rhs.app)
            )
        case .cpu:
            result = compare(lhs.process.cpuSeconds, rhs.process.cpuSeconds)
        case .io:
            result = compare(lhs.process.diskBytes, rhs.process.diskBytes)
        case .wakeups:
            result = compare(lhs.process.wakeups, rhs.process.wakeups)
        case .processCount:
            result = lhs.process.name.localizedCaseInsensitiveCompare(
                rhs.process.name
            )
        }

        if result == .orderedSame {
            return lhs.process.name.localizedCaseInsensitiveCompare(
                rhs.process.name
            ) == .orderedAscending
        }
        return ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compare<T: Comparable>(
        _ lhs: T,
        _ rhs: T
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func batteryMetric(
        percent: Double,
        width: CGFloat,
        compact: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * min(max(percent / max(totalBatteryPercent, 0.01), 0), 1))
                }
            }
            .frame(width: compact ? 52 : 72, height: 7)

            Text(String(format: "%.2f %%", percent))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(compact ? .caption : .callout)
        .frame(width: width, alignment: .trailing)
    }

    private func metric(
        _ text: String,
        _ width: CGFloat,
        _ secondary: Bool = false
    ) -> some View {
        Text(text)
            .font(secondary ? .caption : .callout)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
            .lineLimit(1)
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }

    private func displayProcessName(
        _ process: ProcessEnergyRecord,
        app: AppEnergyRecord
    ) -> String {
        if process.bundleIdentifier == app.bundleIdentifier || process.name == app.name {
            return "\(process.name) (\(l.t("mainProcess")))"
        }
        return process.name
    }
}
