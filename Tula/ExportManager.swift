import Foundation
import SwiftData
import PDFKit
import UIKit

// MARK: - Export Range

/// Preset windows for the Export sheet. Mirrors the filter date presets
/// since users think about exports in the same chunks: "last month's
/// statement", "this year for taxes", etc.
enum ExportRange: String, CaseIterable, Identifiable {
    case thisMonth
    case lastMonth
    case thisYear
    case lastYear
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth:  return "This Month"
        case .lastMonth:  return "Last Month"
        case .thisYear:   return "This Year"
        case .lastYear:   return "Last Year"
        case .allTime:    return "All Time"
        }
    }

    /// Half-open `[start, end)` window for the range, relative to now.
    func interval(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch self {
        case .thisMonth:
            let i = calendar.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 0)
            return (i.start, i.end)
        case .lastMonth:
            guard let prev = calendar.date(byAdding: .month, value: -1, to: now),
                  let i = calendar.dateInterval(of: .month, for: prev) else {
                return (now, now)
            }
            return (i.start, i.end)
        case .thisYear:
            let i = calendar.dateInterval(of: .year, for: now)
                ?? DateInterval(start: now, duration: 0)
            return (i.start, i.end)
        case .lastYear:
            guard let prev = calendar.date(byAdding: .year, value: -1, to: now),
                  let i = calendar.dateInterval(of: .year, for: prev) else {
                return (now, now)
            }
            return (i.start, i.end)
        case .allTime:
            return (.distantPast, .distantFuture)
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case pdf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: return "CSV (Spreadsheet)"
        case .pdf: return "PDF (Report)"
        }
    }

    var fileExtension: String { rawValue }
}

// MARK: - Export Manager

/// Generates expense exports in CSV or PDF formats.
///
/// Architecture: both formats share `ExportInsights` for the heavy
/// computational lifting (totals, breakdowns, daily series) — only the
/// rendering differs.
///
/// PDF renders with branded charts: a category donut, daily-spend bar
/// chart, top categories and merchants tables. CSV gets a compact
/// summary preamble followed by the standard transaction table — works
/// cleanly in Excel/Numbers because the preamble is separated from the
/// data table by a blank line.
enum ExportManager {

    // MARK: - Brand

    /// Brand amber for headers and chart accents. Matches the light
    /// variant of `Color.tulaBrandFallback` — PDFs don't honor dark
    /// mode so we always use the lighter hex.
    private static let brandColor = UIColor(red: 0.85, green: 0.46, blue: 0.10, alpha: 1.0)

    // MARK: - Public API

    static func export(
        expenses: [Expense],
        range: ExportRange,
        format: ExportFormat,
        currencyCode: String
    ) throws -> URL {
        let window = range.interval()
        let filtered = expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .sorted { $0.date > $1.date }

        let insights = ExportInsights.compute(
            expenses: filtered,
            rangeStart: window.start,
            rangeEnd: window.end
        )

        let data: Data
        switch format {
        case .csv:
            data = generateCSV(
                expenses: filtered,
                insights: insights,
                range: range,
                currencyCode: currencyCode
            )
        case .pdf:
            data = generatePDF(
                expenses: filtered,
                insights: insights,
                range: range,
                currencyCode: currencyCode
            )
        }

        let filename = makeFilename(range: range, format: format)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func makeFilename(range: ExportRange, format: ExportFormat) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: .now)
        let slug = range.displayName.lowercased().replacingOccurrences(of: " ", with: "-")
        return "tula-\(slug)-\(today).\(format.fileExtension)"
    }

    // MARK: - CSV

    /// CSV with a summary preamble. Layout:
    ///
    ///     Tula Expense Report
    ///     Range,This Month
    ///     Total,50000.00
    ///     Count,42
    ///     ...
    ///     <blank line>
    ///     Date,Time,Amount,...
    ///     2025-...
    ///
    /// Excel and Numbers handle this cleanly — the preamble shows up as
    /// a small table at the top, the data table starts below the blank
    /// row. Pure-CSV consumers can either ingest both blocks or skip
    /// past the blank line.
    private static func generateCSV(
        expenses: [Expense],
        insights: ExportInsights,
        range: ExportRange,
        currencyCode: String
    ) -> Data {
        var lines: [String] = []

        // Preamble — summary block
        lines.append("Tula Expense Report")
        lines.append("Range,\(range.displayName)")
        if let s = insights.effectiveStart, let e = insights.effectiveEnd {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            lines.append("Period,\(df.string(from: s)) to \(df.string(from: e))")
        }
        lines.append("Currency,\(currencyCode)")
        lines.append("Total,\(String(format: "%.2f", insights.total))")
        lines.append("Count,\(insights.count)")
        lines.append("Average per Expense,\(String(format: "%.2f", insights.averagePerExpense))")
        lines.append("Average per Day,\(String(format: "%.2f", insights.averagePerDay))")
        if let top = insights.categoryBreakdown.first {
            lines.append("Top Category,\(csvEscape(top.name)),\(String(format: "%.2f", top.amount))")
        }
        if let topMerchant = insights.merchantBreakdown.first {
            lines.append("Top Merchant,\(csvEscape(topMerchant.name)),\(String(format: "%.2f", topMerchant.amount))")
        }
        lines.append("Generated,\(ISO8601DateFormatter().string(from: .now))")

        // Blank row before category breakdown
        lines.append("")

        // Category breakdown block
        lines.append("Category Breakdown")
        lines.append("Category,Amount,Count,Percent")
        for stat in insights.categoryBreakdown {
            let pct = insights.total > 0 ? Int((stat.amount / insights.total * 100).rounded()) : 0
            lines.append([
                csvEscape(stat.name),
                String(format: "%.2f", stat.amount),
                "\(stat.count)",
                "\(pct)%"
            ].joined(separator: ","))
        }

        // Blank row before the main transaction table
        lines.append("")

        // Transactions header
        lines.append([
            "Date", "Time", "Amount", "Currency", "Merchant",
            "Category", "Account", "Source", "Note"
        ].joined(separator: ","))

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        for e in expenses {
            let fields = [
                dateFmt.string(from: e.date),
                timeFmt.string(from: e.date),
                String(format: "%.2f", e.amount),
                currencyCode,
                e.merchant ?? "",
                e.category?.name ?? "",
                e.account?.name ?? "",
                e.source.rawValue,
                e.note ?? "",
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }

        let body = lines.joined(separator: "\r\n")
        // BOM (0xEF 0xBB 0xBF) — improves compatibility with Excel.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(body.data(using: .utf8) ?? Data())
        return data
    }

    nonisolated private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") ||
              field.contains("\n") || field.contains("\r") else {
            return field
        }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - PDF

    /// PDF page layout constants — A4 at 72dpi. All rendering is in points.
    private struct PDF {
        static let pageWidth: CGFloat = 595.2
        static let pageHeight: CGFloat = 841.8
        static let margin: CGFloat = 44
        static let bandHeight: CGFloat = 6  // brand-color strip atop each page
    }

    /// Generates the multi-page report. Structure:
    ///   • Page 1 — Cover: header, hero total, stat tiles, period dates
    ///   • Page 2 — Visuals: category donut + legend, daily spend bar chart
    ///   • Page 3 — Breakdowns: top categories table, top merchants table
    ///   • Page 4+ — Transactions table (paginated, header repeats)
    ///
    /// Drawn via Core Graphics inside the UIGraphicsPDFRenderer closure.
    /// Each page begins with a brand-color band and ends with a footer
    /// (brand mark + page number) for a polished look.
    private static func generatePDF(
        expenses: [Expense],
        insights: ExportInsights,
        range: ExportRange,
        currencyCode: String
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: PDF.pageWidth, height: PDF.pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        var pageNumber = 1

        return renderer.pdfData { ctx in
            // ---------------- Page 1 — Cover ----------------
            beginNewPage(ctx, pageRect: pageRect)
            var y = PDF.margin + 8

            y = drawHeader(
                title: "Expense Report",
                subtitle: rangeSubtitle(range: range, insights: insights),
                at: y, pageRect: pageRect
            )

            y += 22

            // Hero total — large
            y = drawHero(
                total: insights.total,
                currencyCode: currencyCode,
                count: insights.count,
                at: y, pageRect: pageRect
            )

            y += 18

            // Stat grid — 2x2 tiles
            y = drawStatGrid(
                insights: insights,
                currencyCode: currencyCode,
                at: y, pageRect: pageRect
            )

            // Footer
            drawFooter(ctx, pageRect: pageRect, page: pageNumber)
            pageNumber += 1

            // ---------------- Page 2 — Visuals ----------------
            guard !insights.categoryBreakdown.isEmpty else {
                // Skip visuals if there's no data — go straight to transactions
                drawTransactionsPages(
                    ctx: ctx, expenses: expenses,
                    currencyCode: currencyCode,
                    pageRect: pageRect,
                    pageNumber: &pageNumber
                )
                return
            }

            beginNewPage(ctx, pageRect: pageRect)
            y = PDF.margin + 8
            y = drawSectionTitle("Visual Breakdown", at: y, pageRect: pageRect)
            y += 12

            // Category donut with legend
            y = drawCategoryDonut(
                insights: insights,
                currencyCode: currencyCode,
                at: y, pageRect: pageRect
            )
            y += 18

            // Daily spend bar chart (if we have multi-day data)
            if insights.dailyTotals.count > 1 {
                y = drawDailySpendChart(
                    insights: insights,
                    currencyCode: currencyCode,
                    at: y, pageRect: pageRect
                )
            }

            drawFooter(ctx, pageRect: pageRect, page: pageNumber)
            pageNumber += 1

            // ---------------- Page 3 — Breakdowns ----------------
            beginNewPage(ctx, pageRect: pageRect)
            y = PDF.margin + 8
            y = drawSectionTitle("By Category", at: y, pageRect: pageRect)
            y += 8
            y = drawCategoryTable(
                insights: insights,
                currencyCode: currencyCode,
                at: y, pageRect: pageRect
            )

            if !insights.merchantBreakdown.isEmpty {
                y += 24
                y = drawSectionTitle("Top Merchants", at: y, pageRect: pageRect)
                y += 8
                y = drawMerchantTable(
                    insights: insights,
                    currencyCode: currencyCode,
                    at: y, pageRect: pageRect
                )
            }

            drawFooter(ctx, pageRect: pageRect, page: pageNumber)
            pageNumber += 1

            // ---------------- Page 4+ — Transactions ----------------
            drawTransactionsPages(
                ctx: ctx, expenses: expenses,
                currencyCode: currencyCode,
                pageRect: pageRect,
                pageNumber: &pageNumber
            )
        }
    }

    // MARK: - PDF: Page Decoration

    /// Brand-amber band across the very top of the page.
    private static func drawBrandBand(_ ctx: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        let band = CGRect(x: 0, y: 0, width: pageRect.width, height: PDF.bandHeight)
        ctx.cgContext.setFillColor(brandColor.cgColor)
        ctx.cgContext.fill(band)
    }

    /// Starts a new PDF page with all standard chrome: band, watermark,
    /// and ready to receive content. Centralizes the page-start ritual
    /// so every page gets consistent decoration without sprinkling
    /// individual `beginPage` / `drawBrandBand` / `drawWatermark` calls
    /// across the rendering code.
    private static func beginNewPage(_ ctx: UIGraphicsPDFRendererContext,
                                       pageRect: CGRect) {
        ctx.beginPage()
        drawBrandBand(ctx, pageRect: pageRect)
        drawWatermark(ctx, pageRect: pageRect)
    }

    /// Brand mark + page number at the bottom of every page.
    private static func drawFooter(_ ctx: UIGraphicsPDFRendererContext,
                                     pageRect: CGRect, page: Int) {
        let footerY = pageRect.height - PDF.margin + 14
        let leftAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: brandColor
        ]
        NSAttributedString(string: "TULA", attributes: leftAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: footerY))

        let pageAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5),
            .foregroundColor: UIColor.gray
        ]
        let pageStr = NSAttributedString(string: "Page \(page)", attributes: pageAttrs)
        let size = pageStr.size()
        pageStr.draw(at: CGPoint(x: pageRect.width - PDF.margin - size.width, y: footerY))
    }

    /// Large Devanagari "तुला" rotated 30° across the center of the page,
    /// drawn at very low opacity so it reads as a watermark behind the
    /// content rather than competing with it. Called BEFORE any text or
    /// charts on each page so subsequent draws layer on top.
    ///
    /// Visual goal: a quiet brand mark that gives the PDF a sense of
    /// origin — like the faded "PAID" stamp on a statement. Anchored at
    /// the page center, sized large enough to feel intentional but
    /// muted enough to never compete with the data.
    private static func drawWatermark(_ ctx: UIGraphicsPDFRendererContext,
                                        pageRect: CGRect) {
        let cg = ctx.cgContext
        // Try Devanagari-capable fonts in order. Most modern iOS builds
        // have Kohinoor Devanagari or Noto Sans Devanagari; we also
        // fall back to system font which on iOS still renders Devanagari
        // glyphs reasonably via fallback chain.
        let font = UIFont(name: "KohinoorDevanagari-Bold", size: 220)
            ?? UIFont(name: "Kohinoor Devanagari Bold", size: 220)
            ?? UIFont(name: "NotoSansDevanagari-Bold", size: 220)
            ?? UIFont.systemFont(ofSize: 220, weight: .bold)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            // Very low opacity — perceptible but not distracting. The
            // brand amber at 6-8% reads as a warm tint rather than a
            // legible word, which is exactly what watermarks should do.
            .foregroundColor: brandColor.withAlphaComponent(0.07)
        ]

        let str = NSAttributedString(string: "तुला", attributes: attrs)
        let textSize = str.size()

        // Save state, rotate around page center, draw, restore.
        cg.saveGState()
        cg.translateBy(x: pageRect.midX, y: pageRect.midY)
        cg.rotate(by: -.pi / 6) // -30 degrees — runs lower-left to upper-right
        str.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        cg.restoreGState()
    }

    // MARK: - PDF: Page 1 — Cover

    /// Returns the y-position after drawing.
    private static func drawHeader(title: String, subtitle: String,
                                     at y: CGFloat, pageRect: CGRect) -> CGFloat {
        // "TULA" wordmark — small caps in brand color
        let wordmark: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .heavy),
            .foregroundColor: brandColor,
            .kern: 2
        ]
        NSAttributedString(string: "TULA", attributes: wordmark)
            .draw(at: CGPoint(x: PDF.margin, y: y))

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: title, attributes: titleAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: y + 14))

        // Subtitle
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel
        ]
        NSAttributedString(string: subtitle, attributes: subtitleAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: y + 46))

        return y + 70
    }

    private static func drawHero(total: Double, currencyCode: String, count: Int,
                                   at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel,
            .kern: 0.5
        ]
        NSAttributedString(string: "TOTAL SPENT", attributes: labelAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: y))

        let amountAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: Currency.format(total, code: currencyCode), attributes: amountAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: y + 16))

        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.secondaryLabel
        ]
        NSAttributedString(string: "\(count) expense\(count == 1 ? "" : "s")",
                           attributes: countAttrs)
            .draw(at: CGPoint(x: PDF.margin, y: y + 72))

        return y + 96
    }

    private static func drawStatGrid(insights: ExportInsights,
                                       currencyCode: String,
                                       at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let availWidth = pageRect.width - 2 * PDF.margin
        let gap: CGFloat = 12
        let tileW = (availWidth - gap) / 2
        let tileH: CGFloat = 70

        let tiles: [(label: String, value: String, sub: String?)] = [
            ("AVERAGE PER EXPENSE",
             Currency.format(insights.averagePerExpense, code: currencyCode),
             nil),
            ("DAILY AVERAGE",
             Currency.format(insights.averagePerDay, code: currencyCode),
             nil),
            ("LARGEST EXPENSE",
             insights.largestExpense.map { Currency.format($0.amount, code: currencyCode) } ?? "—",
             insights.largestExpense?.label),
            ("BIGGEST DAY",
             insights.biggestDay.map { Currency.format($0.total, code: currencyCode) } ?? "—",
             insights.biggestDay.map { formatDay($0.day) })
        ]

        for (i, tile) in tiles.enumerated() {
            let col = i % 2
            let row = i / 2
            let x = PDF.margin + CGFloat(col) * (tileW + gap)
            let ty = y + CGFloat(row) * (tileH + gap)
            drawStatTile(label: tile.label, value: tile.value, sub: tile.sub,
                         rect: CGRect(x: x, y: ty, width: tileW, height: tileH))
        }

        return y + 2 * tileH + gap + 8
    }

    private static func drawStatTile(label: String, value: String, sub: String?, rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()
        // Subtle tile background
        ctx?.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
        path.fill()

        let pad: CGFloat = 12

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel,
            .kern: 0.5
        ]
        NSAttributedString(string: label, attributes: labelAttrs)
            .draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + pad))

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: value, attributes: valueAttrs)
            .draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + pad + 13))

        if let sub = sub {
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9),
                .foregroundColor: UIColor.tertiaryLabel
            ]
            NSAttributedString(string: sub, attributes: subAttrs)
                .draw(in: CGRect(x: rect.minX + pad, y: rect.minY + pad + 38,
                                 width: rect.width - 2 * pad, height: 14))
        }
    }

    // MARK: - PDF: Page 2 — Donut & Daily

    private static func drawSectionTitle(_ text: String,
                                           at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: CGPoint(x: PDF.margin, y: y))
        return y + 24
    }

    /// Donut on the left, legend on the right. Top 5 categories + "Other".
    private static func drawCategoryDonut(insights: ExportInsights,
                                            currencyCode: String,
                                            at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let donutSize: CGFloat = 160
        let donutX = PDF.margin
        let donutY = y
        let center = CGPoint(x: donutX + donutSize / 2, y: donutY + donutSize / 2)
        let lineWidth: CGFloat = 22
        let radius = (donutSize - lineWidth) / 2

        let slices = donutSlices(insights: insights)
        let total = insights.total
        guard total > 0 else { return y }

        let ctx = UIGraphicsGetCurrentContext()
        let gapDegrees: CGFloat = 2.0
        let totalGap = gapDegrees * CGFloat(slices.count)
        let usable = 360 - totalGap
        var cursor: CGFloat = -90

        for slice in slices {
            let span = CGFloat(slice.fraction) * usable
            let start = cursor * .pi / 180
            let end = (cursor + span) * .pi / 180

            ctx?.setStrokeColor(UIColor(cgColor: UIColor.from(hex: slice.colorHex).cgColor).cgColor)
            ctx?.setLineWidth(lineWidth)
            ctx?.setLineCap(.butt)
            ctx?.addArc(center: center, radius: radius,
                        startAngle: start, endAngle: end, clockwise: false)
            ctx?.strokePath()

            cursor += span + gapDegrees
        }

        // Center total
        let totalLabel: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel,
            .kern: 0.5
        ]
        let totalLabelStr = NSAttributedString(string: "TOTAL", attributes: totalLabel)
        let lsize = totalLabelStr.size()
        totalLabelStr.draw(at: CGPoint(x: center.x - lsize.width / 2,
                                         y: center.y - 18))

        let totalAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let totalStr = NSAttributedString(string: Currency.compact(total, code: currencyCode),
                                            attributes: totalAttrs)
        let tsize = totalStr.size()
        totalStr.draw(at: CGPoint(x: center.x - tsize.width / 2,
                                    y: center.y - 5))

        // Legend
        let legendX = donutX + donutSize + 28
        let legendW = pageRect.width - legendX - PDF.margin
        var lY = donutY + 4
        for slice in slices.prefix(6) {
            drawLegendRow(name: slice.name, fraction: slice.fraction,
                          amount: slice.amount,
                          color: UIColor.from(hex: slice.colorHex),
                          currencyCode: currencyCode,
                          rect: CGRect(x: legendX, y: lY, width: legendW, height: 22))
            lY += 24
        }

        return max(donutY + donutSize, lY) + 8
    }

    private static func drawLegendRow(name: String, fraction: Double, amount: Double,
                                        color: UIColor, currencyCode: String,
                                        rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()
        // Color dot
        ctx?.setFillColor(color.cgColor)
        let dot = CGRect(x: rect.minX, y: rect.midY - 4, width: 8, height: 8)
        ctx?.fillEllipse(in: dot)

        // Name
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.label
        ]
        let nameStr = NSAttributedString(string: name, attributes: nameAttrs)
        nameStr.draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 4))

        // Right side — percent + amount
        let pct = Int((fraction * 100).rounded())
        let pctText = "\(pct)% · \(Currency.format(amount, code: currencyCode))"
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let pctStr = NSAttributedString(string: pctText, attributes: pctAttrs)
        let pSize = pctStr.size()
        pctStr.draw(at: CGPoint(x: rect.maxX - pSize.width, y: rect.minY + 5))
    }

    /// Daily spend as vertical brand-color bars. Caps at 31 bars on
    /// screen — if range has more days we display the most recent 31
    /// (longer ranges with 60+ days would render too narrow to read).
    private static func drawDailySpendChart(insights: ExportInsights,
                                              currencyCode: String,
                                              at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let titleH: CGFloat = 22
        let chartH: CGFloat = 110
        let labelH: CGFloat = 14
        let totalH = titleH + chartH + labelH + 12
        let chartW = pageRect.width - 2 * PDF.margin

        // Title
        _ = drawSectionTitle("Daily Spend", at: y, pageRect: pageRect)

        // Slice to most recent N days that fit
        let maxBars = 31
        let series = insights.dailyTotals.suffix(maxBars)
        guard !series.isEmpty else { return y + totalH }
        let maxVal = series.map(\.total).max() ?? 0
        guard maxVal > 0 else { return y + totalH }

        let chartY = y + titleH
        let chartRect = CGRect(x: PDF.margin, y: chartY, width: chartW, height: chartH)

        // Faint baseline grid (0% / 50% / 100%)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setStrokeColor(UIColor(white: 0.9, alpha: 1).cgColor)
        ctx?.setLineWidth(0.5)
        for frac in [0.0, 0.5, 1.0] {
            let gy = chartRect.maxY - chartRect.height * CGFloat(frac)
            ctx?.move(to: CGPoint(x: chartRect.minX, y: gy))
            ctx?.addLine(to: CGPoint(x: chartRect.maxX, y: gy))
            ctx?.strokePath()
        }

        // Bars
        let count = CGFloat(series.count)
        let slotWidth = chartW / count
        let barWidth = slotWidth * 0.55
        let barXOffset = (slotWidth - barWidth) / 2

        ctx?.setFillColor(brandColor.cgColor)
        for (i, point) in series.enumerated() {
            let h = CGFloat(point.total / maxVal) * chartRect.height
            let bx = chartRect.minX + CGFloat(i) * slotWidth + barXOffset
            let by = chartRect.maxY - h
            let barRect = CGRect(x: bx, y: by, width: barWidth, height: max(h, 0))
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: 1.5)
            path.fill()
        }

        // X-axis labels — first, middle, last
        let xLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.secondaryLabel
        ]
        if let first = series.first {
            NSAttributedString(string: formatShortDay(first.day), attributes: xLabelAttrs)
                .draw(at: CGPoint(x: chartRect.minX, y: chartRect.maxY + 4))
        }
        if let last = series.last {
            let str = NSAttributedString(string: formatShortDay(last.day), attributes: xLabelAttrs)
            let s = str.size()
            str.draw(at: CGPoint(x: chartRect.maxX - s.width, y: chartRect.maxY + 4))
        }

        // Y-axis hint — max value annotation
        let maxAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: UIColor.tertiaryLabel
        ]
        let maxStr = NSAttributedString(string: "max \(Currency.compact(maxVal, code: currencyCode))",
                                          attributes: maxAttrs)
        let mSize = maxStr.size()
        maxStr.draw(at: CGPoint(x: chartRect.maxX - mSize.width,
                                  y: chartRect.minY - 2))

        return y + totalH
    }

    // MARK: - PDF: Page 3 — Tables

    /// Top categories as horizontal-bar rows. Bar width proportional to
    /// each category's share — gives a "Where it went" visual without
    /// needing another chart.
    private static func drawCategoryTable(insights: ExportInsights,
                                            currencyCode: String,
                                            at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let rowHeight: CGFloat = 26
        let width = pageRect.width - 2 * PDF.margin
        let maxAmount = insights.categoryBreakdown.first?.amount ?? 1
        var ry = y

        // Show all categories on this page (typically <20 in practice).
        for (idx, stat) in insights.categoryBreakdown.enumerated() {
            // Pagination guard — if we run out of room, bail and continue
            // on next page (caller decides; we stop here).
            if ry + rowHeight > pageRect.height - PDF.margin - 20 { break }

            drawCategoryTableRow(
                stat: stat,
                maxAmount: maxAmount,
                total: insights.total,
                currencyCode: currencyCode,
                rect: CGRect(x: PDF.margin, y: ry, width: width, height: rowHeight)
            )
            ry += rowHeight + 2
            _ = idx
        }
        return ry
    }

    private static func drawCategoryTableRow(stat: CategoryStat,
                                                maxAmount: Double,
                                                total: Double,
                                                currencyCode: String,
                                                rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()
        let color = UIColor.from(hex: stat.colorHex)
        let barFraction = maxAmount > 0 ? CGFloat(stat.amount / maxAmount) : 0
        let percent = total > 0 ? Int((stat.amount / total * 100).rounded()) : 0

        // Background bar (proportional fill)
        ctx?.setFillColor(color.withAlphaComponent(0.12).cgColor)
        let barWidth = rect.width * barFraction
        let barRect = CGRect(x: rect.minX, y: rect.minY, width: barWidth, height: rect.height)
        UIBezierPath(roundedRect: barRect, cornerRadius: 4).fill()

        // Color dot + name
        ctx?.setFillColor(color.cgColor)
        ctx?.fillEllipse(in: CGRect(x: rect.minX + 8, y: rect.midY - 4, width: 8, height: 8))

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: stat.name, attributes: nameAttrs)
            .draw(at: CGPoint(x: rect.minX + 24, y: rect.midY - 7))

        // Right-side: amount and percent
        let amountAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let amountText = "\(Currency.format(stat.amount, code: currencyCode))   \(percent)%"
        let amountStr = NSAttributedString(string: amountText, attributes: amountAttrs)
        let aSize = amountStr.size()
        amountStr.draw(at: CGPoint(x: rect.maxX - aSize.width - 8,
                                     y: rect.midY - 7))
    }

    private static func drawMerchantTable(insights: ExportInsights,
                                            currencyCode: String,
                                            at y: CGFloat, pageRect: CGRect) -> CGFloat {
        let rowHeight: CGFloat = 22
        let width = pageRect.width - 2 * PDF.margin
        var ry = y

        for stat in insights.merchantBreakdown.prefix(10) {
            if ry + rowHeight > pageRect.height - PDF.margin - 20 { break }
            drawMerchantRow(stat: stat, currencyCode: currencyCode,
                            rect: CGRect(x: PDF.margin, y: ry, width: width, height: rowHeight))
            ry += rowHeight
        }
        return ry
    }

    private static func drawMerchantRow(stat: MerchantStat, currencyCode: String,
                                          rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()
        // Subtle bottom border
        ctx?.setStrokeColor(UIColor(white: 0.92, alpha: 1).cgColor)
        ctx?.setLineWidth(0.5)
        ctx?.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx?.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx?.strokePath()

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.label
        ]
        NSAttributedString(string: stat.name, attributes: nameAttrs)
            .draw(at: CGPoint(x: rect.minX, y: rect.midY - 7))

        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let countStr = NSAttributedString(string: "\(stat.count)×", attributes: countAttrs)
        let cs = countStr.size()
        countStr.draw(at: CGPoint(x: rect.maxX - cs.width - 80, y: rect.midY - 6))

        let amountAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let amountStr = NSAttributedString(string: Currency.format(stat.amount, code: currencyCode),
                                             attributes: amountAttrs)
        let as_ = amountStr.size()
        amountStr.draw(at: CGPoint(x: rect.maxX - as_.width, y: rect.midY - 7))
    }

    // MARK: - PDF: Page 4+ — Transactions

    private static func drawTransactionsPages(
        ctx: UIGraphicsPDFRendererContext,
        expenses: [Expense],
        currencyCode: String,
        pageRect: CGRect,
        pageNumber: inout Int
    ) {
        guard !expenses.isEmpty else { return }

        beginNewPage(ctx, pageRect: pageRect)
        var y = PDF.margin + 8
        y = drawSectionTitle("Transactions", at: y, pageRect: pageRect)
        y += 4

        let columnWidths: [CGFloat] = [78, 70, 150, 110, 100]
        let headers = ["Date", "Amount", "Merchant", "Category", "Account"]

        y = drawTableRow(headers, columnWidths: columnWidths,
                           at: y, font: .systemFont(ofSize: 9.5, weight: .semibold),
                           isHeader: true)
        y += 2

        let rowHeight: CGFloat = 26
        let bottomLimit = pageRect.height - PDF.margin - 20
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "d MMM yyyy"

        for (index, expense) in expenses.enumerated() {
            if y + rowHeight > bottomLimit {
                drawFooter(ctx, pageRect: pageRect, page: pageNumber)
                pageNumber += 1
                beginNewPage(ctx, pageRect: pageRect)
                y = PDF.margin + 8
                y = drawSectionTitle("Transactions (cont.)", at: y, pageRect: pageRect)
                y += 4
                y = drawTableRow(headers, columnWidths: columnWidths,
                                   at: y, font: .systemFont(ofSize: 9.5, weight: .semibold),
                                   isHeader: true)
                y += 2
            }

            // Zebra-stripe even rows for legibility — fill matches the
            // taller row so the band doesn't end mid-row.
            if index.isMultiple(of: 2) {
                let ctx2 = UIGraphicsGetCurrentContext()
                ctx2?.setFillColor(UIColor(white: 0.97, alpha: 1).cgColor)
                ctx2?.fill(CGRect(x: PDF.margin, y: y - 4,
                                   width: pageRect.width - 2 * PDF.margin,
                                   height: rowHeight))
            }

            let row = [
                dateFmt.string(from: expense.date),
                Currency.format(expense.amount, code: currencyCode),
                expense.merchant ?? "—",
                expense.category?.name ?? "—",
                expense.account?.name ?? "—"
            ]
            // Render text vertically centered within the taller row so
            // we keep generous padding above and below.
            y = drawTableRow(row, columnWidths: columnWidths,
                               at: y + 4, font: .systemFont(ofSize: 10),
                               isHeader: false,
                               advance: rowHeight - 4)
        }
        drawFooter(ctx, pageRect: pageRect, page: pageNumber)
        pageNumber += 1
    }

    /// Draws a row of right-padded text fields and advances y by the
    /// given amount. `advance` defaults to 18pt for the header use case;
    /// transaction rows override with a taller value for more breathing
    /// room.
    private static func drawTableRow(_ fields: [String], columnWidths: [CGFloat],
                                       at y: CGFloat, font: UIFont,
                                       isHeader: Bool,
                                       advance: CGFloat = 18) -> CGFloat {
        var x = PDF.margin
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isHeader ? UIColor.secondaryLabel : UIColor.label
        ]
        for (i, field) in fields.enumerated() {
            let w = columnWidths[i]
            let rect = CGRect(x: x, y: y, width: w - 8, height: 16)
            NSAttributedString(string: field, attributes: attrs).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                context: nil
            )
            x += w
        }
        return y + advance
    }

    // MARK: - Helpers

    private static func rangeSubtitle(range: ExportRange, insights: ExportInsights) -> String {
        if let s = insights.effectiveStart, let e = insights.effectiveEnd {
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy"
            return "\(range.displayName) · \(df.string(from: s)) – \(df.string(from: e))"
        }
        return range.displayName
    }

    private static func formatDay(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "d MMM"
        return df.string(from: date)
    }

    private static func formatShortDay(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "d MMM"
        return df.string(from: date)
    }

    /// Donut slice helper for the PDF — same shape as the Stats view's
    /// donut. Top 5 categories + "Other".
    private struct PDFDonutSlice {
        let name: String
        let colorHex: String
        let amount: Double
        let fraction: Double
    }

    private static func donutSlices(insights: ExportInsights) -> [PDFDonutSlice] {
        guard insights.total > 0 else { return [] }
        let top = insights.categoryBreakdown.prefix(5)
        let tail = insights.categoryBreakdown.dropFirst(5)

        var slices: [PDFDonutSlice] = top.map { stat in
            PDFDonutSlice(name: stat.name, colorHex: stat.colorHex,
                          amount: stat.amount,
                          fraction: stat.amount / insights.total)
        }
        let tailTotal = tail.reduce(0) { $0 + $1.amount }
        if tailTotal > 0 {
            slices.append(PDFDonutSlice(
                name: "Other", colorHex: "#9CA3AF",
                amount: tailTotal,
                fraction: tailTotal / insights.total
            ))
        }
        return slices
    }
}

// MARK: - UIColor hex helper

extension UIColor {
    /// PDF-side hex initializer mirroring `Color(hex:)`. Returns gray for
    /// malformed input rather than crashing.
    static func from(hex: String) -> UIColor {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgb), cleaned.count == 6 else {
            return .gray
        }
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
