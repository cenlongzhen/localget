import 'package:flutter/material.dart';

/// Centered icon and message shared by the empty states of the share page.
///
/// Scrollable so it also works as the child of a [RefreshIndicator].
class EmptyStateView extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyStateView({required this.icon, required this.message, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 40),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
