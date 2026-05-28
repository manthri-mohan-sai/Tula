//
//  Tula_WidgetLiveActivity.swift
//  Tula Widget
//
//  Created by Mohan Manthri on 27/05/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct Tula_WidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct Tula_WidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Tula_WidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension Tula_WidgetAttributes {
    fileprivate static var preview: Tula_WidgetAttributes {
        Tula_WidgetAttributes(name: "World")
    }
}

extension Tula_WidgetAttributes.ContentState {
    fileprivate static var smiley: Tula_WidgetAttributes.ContentState {
        Tula_WidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: Tula_WidgetAttributes.ContentState {
         Tula_WidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: Tula_WidgetAttributes.preview) {
   Tula_WidgetLiveActivity()
} contentStates: {
    Tula_WidgetAttributes.ContentState.smiley
    Tula_WidgetAttributes.ContentState.starEyes
}
