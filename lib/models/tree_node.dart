class TreeNode {
  final String fullPath;
  final String name;
  final bool isDirectory;
  final int depth;
  bool isExpanded;
  List<TreeNode>? children;

  TreeNode({
    required this.fullPath,
    required this.name,
    required this.isDirectory,
    required this.depth,
    this.isExpanded = false,
    this.children,
  });

  String get extension {
    if (isDirectory) return '';
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }
}