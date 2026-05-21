import 'package:flutter/material.dart';

/// Banner de aviso que o app está em fase Alfa.
///
/// v588: aviso removido (a fase de testes externos amadureceu o suficiente).
/// Mantemos a classe vazia para não quebrar callers (`AlfaScaffold` etc.).
class AlfaBanner extends StatelessWidget {
  const AlfaBanner({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Wrapper que adiciona o banner Alfa acima do conteúdo
/// Use: AlfaScaffold(body: ..., appBar: ...) em vez de Scaffold
class AlfaScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Widget? drawer;
  final Color? backgroundColor;
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  const AlfaScaffold({
    Key? key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.drawer,
    this.backgroundColor,
    this.floatingActionButtonLocation,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      drawer: drawer,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      body: Column(
        children: [
          // Banner Alfa no topo (abaixo da status bar)
          const AlfaBanner(),
          // AppBar customizado
          if (appBar != null) appBar!,
          // Conteúdo principal
          Expanded(child: body),
        ],
      ),
    );
  }
}
