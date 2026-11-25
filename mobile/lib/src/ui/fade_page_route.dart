//! A plain fade between pages, instead of the platform slide:
//! switching pages should feel like swapping content, not
//! travelling sideways. Shared by the top-level destinations and
//! the device page opened from a device card, so every page change
//! in the app feels the same.

import 'package:flutter/material.dart';

class FadePageRoute<T> extends PageRouteBuilder<T> {
  FadePageRoute({required WidgetBuilder builder})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 150),
        reverseTransitionDuration: const Duration(milliseconds: 150),
      );
}
