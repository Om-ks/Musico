import 'dart:async';
import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final double speed;
  final Duration pauseDuration;

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

class _MarqueeTextState extends State<MarqueeText> {
  late ScrollController _scrollController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _resetScroll();
    }
  }

  void _resetScroll() {
    _timer?.cancel();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
    }
  }

  void _startScrolling() async {
    if (!_scrollController.hasClients) return;
    
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;

    await Future.delayed(widget.pauseDuration);
    if (!mounted || !_scrollController.hasClients) return;

    final duration = Duration(milliseconds: (maxScroll / widget.speed * 1000).toInt());

    _timer = Timer.periodic(duration + widget.pauseDuration * 2, (timer) async {
      if (!mounted || !_scrollController.hasClients) {
        timer.cancel();
        return;
      }

      await _scrollController.animateTo(
        maxScroll,
        duration: duration,
        curve: Curves.linear,
      );

      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_scrollController.hasClients) return;

      _scrollController.jumpTo(0);
      await Future.delayed(widget.pauseDuration);
    });
    
    // Trigger first animation
    await _scrollController.animateTo(
      maxScroll,
      duration: duration,
      curve: Curves.linear,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
      ),
    );
  }
}
