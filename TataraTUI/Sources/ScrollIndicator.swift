// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftTUI
import TataraCore

struct ScrollIndicator: View {
  let metrics: ScrollMetrics
  let palette: Palette
  let scroll: @MainActor (Int) -> Void

  var body: some View {
    if metrics.isScrollable {
      indicator
        .fixedSize(horizontal: true, vertical: true)
        .frame(width: 1, height: metrics.track)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
          scroll(metrics.offset(at: value.location.y))
        })
    }
  }

  private var indicator: Text {
    var content = Text.StringInterpolation(literalCapacity: 0, interpolationCount: metrics.track)
    for row in 0 ..< metrics.track {
      if row > 0 {
        content.appendLiteral("\n")
      }
      let thumb = (metrics.thumbStart ..< (metrics.thumbStart + metrics.thumbLength)).contains(row)
      content.appendInterpolation(Text(thumb ? "█" : "│").foregroundStyle(thumb ? palette.accent : palette.surface))
    }
    return Text(Text.RichContent(stringInterpolation: content))
  }
}
