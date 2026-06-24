// Manager media library — reusable in two shapes:
//
//   * [MediaLibrarySection] — an inline card for the Settings page: upload,
//     browse, and delete the studio's images in one place.
//   * [showMediaPicker] — a dialog that does the same but RETURNS the chosen
//     image's URL, for dropping into an image field (splash today; logos,
//     promos, etc. later).
//
// Uploads are manager-only (the server gates /admin/media), go through the Go
// API to Firebase Storage, and come back as a plain download URL.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminMediaProvider = FutureProvider<List<MediaItem>>((ref) async {
  return ref.watch(apiClientProvider).adminListMedia();
});

/// Maps a picked file's extension to a MIME the server accepts. Keep in sync
/// with the server's allowedImageMIME.
String? _mimeForExtension(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return null;
  }
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Picks an image from the device and uploads it to the library. Returns the
/// new item, or null if the manager cancelled or it failed (failures toast).
/// Invalidates [adminMediaProvider] on success so any open view refreshes.
Future<MediaItem?> pickAndUploadImage(
  BuildContext context,
  WidgetRef ref,
) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: true,
  );
  if (!context.mounted) return null;
  if (picked == null || picked.files.isEmpty) return null; // cancelled
  final f = picked.files.first;
  final bytes = f.bytes;
  if (bytes == null) {
    _toast(context, 'Could not read that file.');
    return null;
  }
  final mime = _mimeForExtension(f.extension ?? '');
  if (mime == null) {
    _toast(context, 'Unsupported type — use png, jpg, webp or gif.');
    return null;
  }
  try {
    final item = await ref
        .read(apiClientProvider)
        .adminUploadMedia(bytes: bytes, filename: f.name, mime: mime);
    ref.invalidate(adminMediaProvider);
    return item;
  } catch (e) {
    if (context.mounted) {
      _toast(context, 'Upload failed: ${ApiError.fromAny(e).message}');
    }
    return null;
  }
}

/// Confirms then deletes [item] from the library. Returns true on success.
Future<bool> confirmAndDeleteMedia(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete image?'),
      content: const Text(
        'Removes it from the library. Anywhere already using it keeps the '
        'link until you change it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await ref.read(apiClientProvider).adminDeleteMedia(item.id);
    ref.invalidate(adminMediaProvider);
    return true;
  } catch (e) {
    if (context.mounted) {
      _toast(context, 'Delete failed: ${ApiError.fromAny(e).message}');
    }
    return false;
  }
}

// ============================ Settings card =============================

/// Inline media library for the Settings page: upload, browse, delete.
class MediaLibrarySection extends ConsumerStatefulWidget {
  const MediaLibrarySection({super.key});

  @override
  ConsumerState<MediaLibrarySection> createState() =>
      _MediaLibrarySectionState();
}

class _MediaLibrarySectionState extends ConsumerState<MediaLibrarySection> {
  bool _uploading = false;

  Future<void> _upload() async {
    setState(() => _uploading = true);
    await pickAndUploadImage(context, ref);
    if (mounted) setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final media = ref.watch(adminMediaProvider);
    return ManagerCard(
      title: 'Images',
      action: _uploading ? 'Uploading…' : '+ Upload',
      onAction: _uploading ? null : _upload,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Upload photos to use as splash backgrounds and elsewhere in the '
            'app. Pick one as a theme splash in the Themes panel.',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          media.when(
            data: (items) => items.isEmpty
                ? _hint(y)
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final item in items)
                        SizedBox(
                          width: 96,
                          height: 68,
                          child: _MediaTile(
                            item: item,
                            onDelete: () =>
                                confirmAndDeleteMedia(context, ref, item),
                          ),
                        ),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (e, _) => Text(
              "Can't load images: ${ApiError.fromAny(e).message}",
              style: TextStyle(color: y.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hint(YogaTokens y) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(
      'No images yet — tap Upload to add one.',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: y.muted,
      ),
    ),
  );
}

// ============================ Picker dialog ============================

/// Opens the library picker. Resolves to the selected image URL, or null if
/// the manager cancelled.
Future<String?> showMediaPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _MediaPickerDialog(),
  );
}

class _MediaPickerDialog extends ConsumerStatefulWidget {
  const _MediaPickerDialog();

  @override
  ConsumerState<_MediaPickerDialog> createState() => _MediaPickerDialogState();
}

class _MediaPickerDialogState extends ConsumerState<_MediaPickerDialog> {
  bool _uploading = false;

  Future<void> _upload() async {
    setState(() => _uploading = true);
    final item = await pickAndUploadImage(context, ref);
    if (!mounted) return;
    setState(() => _uploading = false);
    // Newly uploaded → pick it straight away; the manager almost always
    // wants the thing they just added.
    if (item != null) Navigator.of(context).pop(item.url);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final media = ref.watch(adminMediaProvider);
    return Dialog(
      backgroundColor: y.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Media library',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                      ),
                    ),
                  ),
                  YButton(
                    label: _uploading ? 'Uploading…' : '+ Upload',
                    small: true,
                    onTap: _uploading ? null : _upload,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: media.when(
                  data: (items) => items.isEmpty
                      ? _empty(y)
                      : GridView.builder(
                          shrinkWrap: true,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                childAspectRatio: 1.2,
                              ),
                          itemCount: items.length,
                          itemBuilder: (_, i) => _MediaTile(
                            item: items[i],
                            onTap: () =>
                                Navigator.of(context).pop(items[i].url),
                            onDelete: () =>
                                confirmAndDeleteMedia(context, ref, items[i]),
                          ),
                        ),
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (e, _) => Center(
                    child: Text(
                      "Can't load library: ${ApiError.fromAny(e).message}",
                      style: TextStyle(color: y.muted),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(YogaTokens y) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'No images yet — tap Upload to add one.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.muted,
        ),
      ),
    ),
  );
}

/// Thumbnail with a delete affordance. [onTap] is the select action — null in
/// the management card (where tapping shouldn't pick anything), set in the
/// picker dialog (where it returns the URL).
class _MediaTile extends StatelessWidget {
  final MediaItem item;
  final VoidCallback? onTap;
  final VoidCallback onDelete;
  const _MediaTile({required this.item, this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              item.url,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: y.surface2,
                alignment: Alignment.center,
                child: Icon(Icons.broken_image, color: y.muted, size: 20),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Color(0x99000000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
