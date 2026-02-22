import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// A regex that matches http:// and https:// URLs.
final _urlRegex = RegExp(r'https?://[^\s<>"]+');

/// A [Text]-like widget that detects URLs in its content and makes them
/// clickable.  Non-URL portions inherit the given [style]; URLs are rendered
/// with an underline so they look like hyperlinks.
class LinkifiedText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const LinkifiedText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: style);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final m in matches) {
      // Text before this URL
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, m.start), style: style));
      }
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: (style ?? const TextStyle()).copyWith(
          decoration: TextDecoration.underline,
          decorationColor: style?.color ?? Colors.lightBlueAccent,
          color: Colors.lightBlueAccent,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            launcher.launchUrl(
              Uri.parse(url),
              mode: launcher.LaunchMode.externalApplication,
            );
          },
      ));
      lastEnd = m.end;
    }

    // Remaining text after the last URL
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: style));
    }

    return RichText(text: TextSpan(children: spans));
  }
}
