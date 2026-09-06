import 'dart:ui';
import 'package:flutter/material.dart';

// A reusable frosted-glass container (glassmorphism effect) utilizing BackdropFilter
// to blur the background content behind it and render a translucent tinted surface with subtle borders.
class GlassContainer extends StatelessWidget {
  // The child widget rendered inside the glass container.
  final Widget child;

  // The Gaussian blur radius (sigmaX and sigmaY) applied to the backdrop.
  final double blur;

  // The opacity of the white translucent tint layer.
  final double opacity;

  // Optional custom rounded border radius (defaults to circular 16).
  final BorderRadiusGeometry? borderRadius;

  // Inner padding between the glass border and child content.
  final EdgeInsetsGeometry? padding;

  // Outer margin surrounding the glass container.
  final EdgeInsetsGeometry? margin;

  // Optional fixed width for the container.
  final double? width;

  // Optional fixed height for the container.
  final double? height;

  // Optional custom border (defaults to a subtle translucent white 1px outline).
  final BoxBorder? border;

  // Constructor requiring the child widget, with customizable blur, opacity, and styling.
  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 12.0,
    this.opacity = 0.05,
    this.borderRadius,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.circular(16);
    return Container(
      margin: margin,
      width: width,
      height: height,
      // Clip the blurred backdrop filter to the container's rounded corner boundaries.
      child: ClipRRect(
        borderRadius: br,
        // Applies the Gaussian blur filter to whatever widgets are underneath this container.
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              // Translucent white overlay gives the frosted look.
              color: Colors.white.withValues(alpha: opacity),
              borderRadius: br,
              // Subtle semi-transparent border simulates a glass edge catching light.
              border: border ??
                  Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 1,
                  ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
