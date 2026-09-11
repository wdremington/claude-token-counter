import Charts
import SwiftUI

/// Stacked cost (or token) usage over the selected range, one series per model.
struct UsageChart: View {
    let aggregates: Aggregates
    let metric: ChartMetric
    let colorMap: ModelColorMap

    @State private var rawSelection: Date?

    /// Past this many buckets bars get too thin to read, so switch to areas.
    private let areaThreshold = 120

    private var useArea: Bool { aggregates.bucketStarts.count > areaThreshold }

    private var legendNames: [String] {
        aggregates.seriesKeys.map { aggregates.seriesNames[$0] ?? $0 }
    }

    private var legendColors: [Color] {
        aggregates.seriesKeys.map { Palette.series(colorMap.slot(for: $0)) }
    }

    /// The chart's own bucket nearest the pointer.
    private var selectedBucket: Date? {
        guard let rawSelection else { return nil }
        return aggregates.bucketStarts.min {
            abs($0.timeIntervalSince(rawSelection)) < abs($1.timeIntervalSince(rawSelection))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if aggregates.series.isEmpty {
                emptyChart
            } else {
                chart
            }
        }
        .card(padding: 14)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(metric.title) over time")
                .font(.system(size: 13, weight: .semibold))
            Text("· \(aggregates.unit.title.lowercased())")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if let bucket = selectedBucket {
                Text(Fmt.bucketTitle(bucket, unit: aggregates.unit))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(aggregates.series) { point in
                if useArea {
                    AreaMark(
                        x: .value("Time", point.bucketStart, unit: aggregates.unit.component),
                        y: .value(metric.title, point.value(for: metric)),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Model", point.displayName))
                    .interpolationMethod(.monotone)
                } else {
                    BarMark(
                        x: .value("Time", point.bucketStart, unit: aggregates.unit.component),
                        y: .value(metric.title, point.value(for: metric))
                    )
                    .foregroundStyle(by: .value("Model", point.displayName))
                    .cornerRadius(2)
                }
            }

            if let bucket = selectedBucket {
                RuleMark(x: .value("Selected", bucket, unit: aggregates.unit.component))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.22))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        tooltip(for: bucket)
                    }
            }
        }
        .chartForegroundStyleScale(domain: legendNames, range: legendColors)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXSelection(value: $rawSelection)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(metric == .cost ? Fmt.moneyCompact(d) : Fmt.tokens(Int(d)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(Fmt.axisLabel(d, unit: aggregates.unit))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 240)
    }

    /// Per-model readout for the hovered bucket.
    private func tooltip(for bucket: Date) -> some View {
        let points = aggregates.points(at: bucket).filter { $0.value(for: metric) > 0 }
        let total = aggregates.total(at: bucket, metric: metric)

        return VStack(alignment: .leading, spacing: 3) {
            Text(Fmt.bucketTitle(bucket, unit: aggregates.unit))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if points.isEmpty {
                Text("No usage")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(points) { point in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.series(colorMap.slot(for: point.seriesKey)))
                            .frame(width: 8, height: 8)
                        Text(point.displayName)
                            .font(.system(size: 11))
                        Spacer(minLength: 10)
                        Text(format(point.value(for: metric)))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                }
                Divider().padding(.vertical, 1)
                HStack(spacing: 6) {
                    Text("Total").font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 10)
                    Text(format(total))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(8)
        .frame(minWidth: 170, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func format(_ value: Double) -> String {
        metric == .cost ? Fmt.money(value) : Fmt.tokens(Int(value))
    }

    private var emptyChart: some View {
        Text("No usage in this range")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 240)
    }
}
