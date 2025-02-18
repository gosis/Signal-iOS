//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public struct NSRangedValue<T> {
    public let range: NSRange
    public let value: T

    public init( _ value: T, range: NSRange) {
        self.range = range
        self.value = value
    }
}

extension NSRangedValue: Equatable where T: Equatable {}

extension NSRangedValue: Hashable where T: Hashable {}

/// The result of stripping, filtering, and hydrating mentions in a `MessageBody`.
/// This object can be held durably in memory as a way to cache mention hydrations
/// and other expensive string operations, and can subsequently be transformed
/// into string and attributed string values for display.
public class HydratedMessageBody: Equatable, Hashable {

    public typealias Style = MessageBodyRanges.Style

    private let hydratedText: String
    private let unhydratedMentions: [NSRangedValue<MentionAttribute>]
    private let mentionAttributes: [NSRangedValue<MentionAttribute>]
    private let styleAttributes: [NSRangedValue<StyleAttribute>]

    public static func == (lhs: HydratedMessageBody, rhs: HydratedMessageBody) -> Bool {
        return lhs.hydratedText == rhs.hydratedText
            && lhs.mentionAttributes == rhs.mentionAttributes
            && lhs.styleAttributes == rhs.styleAttributes
            && lhs.unhydratedMentions == rhs.unhydratedMentions
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hydratedText)
        hasher.combine(unhydratedMentions)
        hasher.combine(mentionAttributes)
        hasher.combine(styleAttributes)
    }

    internal init(
        hydratedText: String,
        unhydratedMentions: [NSRangedValue<MentionAttribute>] = [],
        mentionAttributes: [NSRangedValue<MentionAttribute>],
        styleAttributes: [NSRangedValue<StyleAttribute>]
    ) {
        self.hydratedText = hydratedText
        self.unhydratedMentions = unhydratedMentions
        self.mentionAttributes = mentionAttributes
        self.styleAttributes = styleAttributes
    }

    internal init(
        messageBody: MessageBody,
        mentionHydrator: MentionHydrator,
        isRTL: Bool = CurrentAppContext().isRTL
    ) {
        guard messageBody.text.isEmpty.negated else {
            self.hydratedText = ""
            self.unhydratedMentions = []
            self.mentionAttributes = []
            self.styleAttributes = []
            return
        }

        let originalText = messageBody.text as NSString
        let filteredText = originalText.filterStringForDisplay() as NSString

        // NOTE that we only handle leading characters getting stripped;
        // if characters in the middle of the string get stripped that
        // will mess up all the ranges. That is not now and never has been
        // handled by the app.
        let strippedPrefixLength: Int
        if filteredText.length != originalText.length {
            // We filtered things, we need to adjust ranges.
            strippedPrefixLength = originalText.range(of: filteredText as String).location
        } else {
            strippedPrefixLength = 0
        }
        var mentionsInOriginal: [(NSRange, UUID)]
        var stylesInOriginal: [(NSRange, Style)]
        if strippedPrefixLength != 0 {
            mentionsInOriginal = messageBody.ranges.orderedMentions.map { range, uuid in
                return (
                    NSRange(
                        location: range.location + strippedPrefixLength,
                        length: range.length
                    ),
                    uuid
                )
            }
            stylesInOriginal = messageBody.ranges.styles.map { range, style in
                return (
                    NSRange(
                        location: range.location + strippedPrefixLength,
                        length: range.length
                    ),
                    style
                )
            }
        } else {
            mentionsInOriginal = messageBody.ranges.orderedMentions
            stylesInOriginal = messageBody.ranges.styles
        }

        let finalText = NSMutableString(string: filteredText)
        var unhydratedMentions = [NSRangedValue<MentionAttribute>]()
        var finalStyleAttributes = [NSRangedValue<StyleAttribute>]()
        var finalMentionAttributes = [NSRangedValue<MentionAttribute>]()

        var rangeOffset = 0

        struct ProcessingStyle {
            let originalRange: NSRange
            let newRange: NSRange
            let style: Style
        }
        var styleAtCurrentIndex: ProcessingStyle?

        let startLength = (filteredText as NSString).length
        for currentIndex in 0..<startLength {
            // If we are past the end, apply the active style to the final result
            // and drop.
            if
                let style = styleAtCurrentIndex,
                currentIndex >= style.originalRange.upperBound
            {
                finalStyleAttributes.append(.init(
                    StyleAttribute.fromOriginalRange(
                        style.originalRange,
                        style: style.style
                    ),
                    range: style.newRange
                ))
                styleAtCurrentIndex = nil
            }
            // Check for any new styles starting at the current index.
            if stylesInOriginal.first?.0.contains(currentIndex) == true {
                let (originalRange, style) = stylesInOriginal.removeFirst()
                styleAtCurrentIndex = .init(
                    originalRange: originalRange,
                    newRange: NSRange(
                        location: originalRange.location + rangeOffset,
                        length: originalRange.length
                    ),
                    style: style
                )
            }

            // Check for any mentions at the current index.
            // Mentions can't overlap, so we don't need a while loop to check for multiple.
            guard
                let (originalMentionRange, mentionUuid) = mentionsInOriginal.first,
                (
                    originalMentionRange.contains(currentIndex)
                    || originalMentionRange.location == currentIndex
                )
            else {
                // No mentions, so no additional logic needed, just go to the next index.
                continue
            }
            mentionsInOriginal.removeFirst()

            let newMentionRange = NSRange(
                location: originalMentionRange.location + rangeOffset,
                length: originalMentionRange.length
            )

            let finalMentionLength: Int
            let mentionOffsetDelta: Int
            switch mentionHydrator(mentionUuid) {
            case .preserveMention:
                // Preserve the mention without replacement and proceed.
                unhydratedMentions.append(.init(
                    MentionAttribute.fromOriginalRange(originalMentionRange, mentionUuid: mentionUuid),
                    range: newMentionRange
                ))
                continue
            case let .hydrate(displayName):
                let mentionPlaintext: String
                if isRTL {
                    mentionPlaintext = displayName + MentionAttribute.mentionPrefix
                } else {
                    mentionPlaintext = MentionAttribute.mentionPrefix + displayName
                }
                finalMentionLength = (mentionPlaintext as NSString).length
                mentionOffsetDelta = finalMentionLength - originalMentionRange.length
                finalText.replaceCharacters(in: newMentionRange, with: mentionPlaintext)
                finalMentionAttributes.append(.init(
                    MentionAttribute.fromOriginalRange(originalMentionRange, mentionUuid: mentionUuid),
                    range: NSRange(location: newMentionRange.location, length: finalMentionLength)
                ))
            }
            rangeOffset += mentionOffsetDelta

            // We have to adjust style ranges for the active style
            if let style = styleAtCurrentIndex {
                if style.originalRange.upperBound <= originalMentionRange.upperBound {
                    // If the style ended inside (or right at the end of) the mention,
                    // it should now end at the end of the replacement text.
                    let finalLength = (newMentionRange.location + finalMentionLength) - style.newRange.location
                    finalStyleAttributes.append(.init(
                        StyleAttribute.fromOriginalRange(
                            style.originalRange,
                            style: style.style
                        ),
                        range: NSRange(
                            location: style.newRange.location,
                            length: finalLength
                        )
                    ))

                    // We are done with it, now.
                    styleAtCurrentIndex = nil
                } else {
                    // The original style ends past the mention; extend its
                    // length by the right amount, but keep it in
                    // the current styles being walked through.
                    styleAtCurrentIndex = .init(
                        originalRange: style.originalRange,
                        newRange: NSRange(
                            location: style.newRange.location,
                            length: style.newRange.length + mentionOffsetDelta
                        ),
                        style: style.style
                    )
                }
            }
        }

        if let style = styleAtCurrentIndex {
            // Styles that ran right to the end (or overran) should be finalized.
            let finalRange = NSRange(
                location: style.newRange.location,
                length: finalText.length - style.newRange.location
            )
            finalStyleAttributes.append(.init(
                StyleAttribute.fromOriginalRange(
                    style.originalRange,
                    style: style.style
                ),
                range: finalRange
            ))
        }

        self.hydratedText = finalText.stringOrNil ?? ""
        self.unhydratedMentions = unhydratedMentions
        self.styleAttributes = finalStyleAttributes
        self.mentionAttributes = finalMentionAttributes
    }

    // MARK: - Displaying as NSAttributedString

    public struct DisplayConfiguration {
        public let mention: MentionDisplayConfiguration
        public let style: StyleDisplayConfiguration

        public struct SearchRanges: Equatable {
            public let matchingBackgroundColor: ThemedColor
            public let matchingForegroundColor: ThemedColor
            public let matchedRanges: [NSRange]

            public init(
                matchingBackgroundColor: ThemedColor,
                matchingForegroundColor: ThemedColor,
                matchedRanges: [NSRange]
            ) {
                self.matchingBackgroundColor = matchingBackgroundColor
                self.matchingForegroundColor = matchingForegroundColor
                self.matchedRanges = matchedRanges
            }
        }

        public let searchRanges: SearchRanges?

        public init(
            mention: MentionDisplayConfiguration,
            style: StyleDisplayConfiguration,
            searchRanges: SearchRanges?
        ) {
            self.mention = mention
            self.style = style
            self.searchRanges = searchRanges
        }
    }

    public func asAttributedStringForDisplay(
        config: DisplayConfiguration,
        isDarkThemeEnabled: Bool
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(string: hydratedText)
        return Self.applyAttributes(
            on: string,
            mentionAttributes: mentionAttributes,
            styleAttributes: styleAttributes,
            config: config,
            isDarkThemeEnabled: isDarkThemeEnabled
        )
    }

    private static let searchRangeConfigKey = NSAttributedString.Key("OWS.searchRange")

    internal static func applyAttributes(
        on string: NSMutableAttributedString,
        mentionAttributes: [NSRangedValue<MentionAttribute>],
        styleAttributes: [NSRangedValue<StyleAttribute>],
        config: HydratedMessageBody.DisplayConfiguration,
        isDarkThemeEnabled: Bool
    ) -> NSMutableAttributedString {
        // Start by removing the background color attribute on the
        // whole string. This is brittle but a big efficiency gain.

        // Consider the scenario where we have a mention under a spoiler
        // and reveal the spoiler.
        // The attributed string we get will have the spoiler background.
        // If we didn't have a mention, the style application would need
        // to wipe the background color in order to reveal; but if we do
        // have a mention doing so will clear the mention style too!

        // The most efficient solution is to always start by clearing
        // out the background, so that the revealed spoiler knows it can
        // do nothing, and it won't wipe the mention attribute.

        // This should be revisited in the future with a more complex solution
        // if there are more overlapping attributes; as of writing only the
        // background color is used by mentions and styles and search.
        string.removeAttribute(.backgroundColor, range: string.entireRange)

        mentionAttributes.forEach {
            $0.value.applyAttributes(
                to: string,
                at: $0.range,
                config: config.mention,
                isDarkThemeEnabled: isDarkThemeEnabled
            )
        }

        // Search takes priority over mentions, but not spoiler styles.
        if let searchRanges = config.searchRanges {
            for searchMatchRange in searchRanges.matchedRanges {
                string.addAttributes(
                    [
                        .backgroundColor: searchRanges.matchingBackgroundColor.color(isDarkThemeEnabled: isDarkThemeEnabled),
                        .foregroundColor: searchRanges.matchingForegroundColor.color(isDarkThemeEnabled: isDarkThemeEnabled),
                        Self.searchRangeConfigKey: config.searchRanges as Any
                    ],
                    range: searchMatchRange
                )
            }
        }

        styleAttributes.forEach {
            $0.value.applyAttributes(
                to: string,
                at: $0.range,
                config: config.style,
                searchRanges: config.searchRanges,
                isDarkThemeEnabled: isDarkThemeEnabled
            )
        }
        return string
    }

    internal static func extractSearchRangeConfigFromAttributes(
        _ attrs: [NSAttributedString.Key: Any]
    ) -> DisplayConfiguration.SearchRanges? {
        return attrs[Self.searchRangeConfigKey] as? DisplayConfiguration.SearchRanges
    }

    // MARK: - Displaying as Plaintext

    public func asPlaintext() -> String {
        let mutableString = NSMutableString(string: hydratedText)
        styleAttributes.forEach {
            $0.value.applyPlaintextSpoiler(to: mutableString, at: $0.range)
        }
        return mutableString as String
    }

    // MARK: - Forwarding

    public func asMessageBodyForForwarding() -> MessageBody {
        var unhydratedMentionsDict = [NSRange: UUID]()
        unhydratedMentions.forEach {
            unhydratedMentionsDict[$0.range] = $0.value.mentionUuid
        }
        return MessageBody(
            text: hydratedText,
            ranges: MessageBodyRanges(
                mentions: unhydratedMentionsDict,
                styles: styleAttributes.map {
                    return ($0.range, $0.value.style)
                }
            )
        )
    }
}
