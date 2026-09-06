import 'dart:async';
import 'package:flutter/material.dart';

// A custom marquee widget that smoothly auto-scrolls text horizontally when it overflows its container,
// pausing at the beginning and end of each scroll cycle.
class MarqueeText extends StatefulWidget {
  // The string of text to display and potentially scroll.
  final String text;

  // The typography style (font, size, color) applied to the text.
  final TextStyle? style;

  // Scrolling speed in pixels per second.
  final double speed;

  // Duration to pause at the start and end of the scrolling cycle before restarting.
  final Duration pauseDuration;

  // Constructor requiring the text string, with optional styling, speed, and pause settings.
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.speed = 50.0,
    this.pauseDuration = const Duration(seconds: 2),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

// State class managing the automatic horizontal scroll animation and timer loop.
class _MarqueeTextState extends State<MarqueeText> {
  // Controls the horizontal scroll offset of the SingleChildScrollView.
  late ScrollController _scrollController;

  // Repeating timer that drives periodic scroll iterations.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    // Schedule scrolling after the layout frame is rendered so maxScrollExtent is known.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }

  // Detects when the parent widget passes a new text string (e.g. song changed).
  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _resetScroll();
    }
  }

  // Cancels any running animation, resets the scroll position to the start, and restarts scrolling.
  void _resetScroll() {
    _timer?.cancel();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
    }
  }

  // Measures overflow extent and orchestrates the continuous linear scroll and pause cycle.
  void _startScrolling() async {
    if (!_scrollController.hasClients) return;
    
    // Check how many pixels the text overflows beyond its visible bounds.
    final maxScroll = _scrollController.position.maxScrollExtent;
    // If text comfortably fits without overflow, do not scroll.
    if (maxScroll <= 0) return;

    // Wait for the initial pause duration before beginning the scroll.
    await Future.delayed(widget.pauseDuration);
    if (!mounted || !_scrollController.hasClients) return;

    // Calculate animation time based on scroll distance and target speed.
    final duration = Duration(milliseconds: (maxScroll / widget.speed * 1000).toInt());

    // Set up repeating timer to scroll back and forth indefinitely.
    _timer = Timer.periodic(duration + widget.pauseDuration * 2, (timer) async {
      if (!mounted || !_scrollController.hasClients) {
        timer.cancel();
        return;
      }

      // Smoothly animate to the end of the text.
      await _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      );

      // Pause at the end of the text.
      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_scrollController.hasClients) return;

      // Jump back to the start and pause before repeating.
      _scrollController.jumpTo(0);
      await Future.delayed(widget.pauseDuration);
    });
    
    // Trigger the initial scroll animation.
    await _scrollController.animateTo(
      maxScroll,
      duration: duration,
      curve: Curves.linear,
    );
  }

  // Cleans up the timer and scroll controller to prevent memory leaks when widget is unmounted.
  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // Renders the horizontally scrollable single line of text with manual physics disabled.
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(), // Disables user drag touch interactions
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
      ),
    );
  }
}
