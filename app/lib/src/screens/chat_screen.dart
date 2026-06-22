// Group chat + direct messages.
//
// Two screens live here:
//   * [ChatListScreen]  — the inbox: every conversation the user belongs to,
//     newest activity first, with unread badges. Polled on PollingSurface
//     .chatList so unread counts refresh in the background.
//   * [ChatThreadScreen] — one open conversation. Loads the most recent page,
//     loads older messages as you scroll up (keyset `before`), and polls for
//     new ones (keyset `after`) on PollingSurface.chatThread. Marks the
//     conversation read as messages arrive.
//
// Starting a conversation is staff-only (the server gates it); the compose
// entry points live in chat_compose.dart and only render for staff.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'chat_compose.dart';

/// The caller's conversations. Session-scoped (not autoDispose) so returning
/// to the inbox shows the cached list immediately while a background refresh
/// runs — same rationale as [notificationsProvider].
final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  return ref.watch(apiClientProvider).conversations();
});

/// Sum of unread messages across every conversation — drives the badge on the
/// More tab + the chat row. Zero while loading/errored so it never flickers.
final totalUnreadChatProvider = Provider<int>((ref) {
  final convs = ref.watch(conversationsProvider);
  final list = convs.asData?.value ?? const <Conversation>[];
  return list.fold<int>(0, (sum, c) => sum + c.unreadCount);
});

class ChatListScreen extends ConsumerWidget {
  final Me me;
  const ChatListScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final convs = ref.watch(conversationsProvider);
    return PollingRefresh(
      surface: PollingSurface.chatList,
      onPoll: () => ref.invalidate(conversationsProvider),
      child: Scaffold(
        backgroundColor: y.background,
        appBar: AppBar(
          backgroundColor: y.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: y.text,
          title: Text(
            'Messages',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: y.text,
            ),
          ),
        ),
        floatingActionButton: me.isStaff
            ? FloatingActionButton(
                backgroundColor: y.primary,
                foregroundColor: y.onPrimary,
                onPressed: () => startNewConversation(context, ref, me),
                child: const Icon(Icons.edit_outlined),
              )
            : null,
        body: SafeArea(
          top: false,
          child: convs.when(
            data: (list) => list.isEmpty
                ? _EmptyInbox(isStaff: me.isStaff)
                : RefreshIndicator(
                    onRefresh: () async =>
                        ref.invalidate(conversationsProvider),
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: list.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: y.border, indent: 76),
                      itemBuilder: (_, i) =>
                          _ConversationTile(conversation: list[i], me: me),
                    ),
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text(
                "Can't load messages: ${ApiError.fromAny(e).message}",
                style: TextStyle(color: y.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  final bool isStaff;
  const _EmptyInbox({required this.isStaff});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 44, color: y.muted),
            const SizedBox(height: 14),
            Text(
              'No conversations yet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isStaff
                  ? 'Start a group or message a student with the button below.'
                  : 'When a teacher messages you, it’ll show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: y.muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  final Conversation conversation;
  final Me me;
  const _ConversationTile({required this.conversation, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final title = conversation.displayTitle(me.id);
    final other = conversation.otherMember(me.id);
    final last = conversation.lastMessage;
    final unread = conversation.unreadCount;

    final preview = last == null
        ? 'No messages yet'
        : last.isDeleted
        ? 'Message removed'
        : '${_previewPrefix(last)}${last.body}';

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatThreadScreen(
              conversationId: conversation.id,
              initialConversation: conversation,
              me: me,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            conversation.isDm
                ? YAvatar(
                    name: title,
                    photoUrl: other?.photoUrl,
                    size: 46,
                    tone: YAvatarTone.primary,
                  )
                : _GroupAvatar(size: 46),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: y.text,
                          ),
                        ),
                      ),
                      if (last != null)
                        Text(
                          _fmtRelative(last.createdAt),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: unread > 0 ? y.primary : y.muted,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: unread > 0
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: unread > 0 ? y.text : y.muted,
                          ),
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: unread),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _previewPrefix(ChatMessage last) {
    // In a group, show who spoke. In a dm, only prefix the user's own lines.
    if (conversation.isDm) {
      return last.senderId == me.id ? 'You: ' : '';
    }
    final who = last.senderId == me.id
        ? 'You'
        : last.senderName.split(' ').first;
    return '$who: ';
  }
}

class _GroupAvatar extends StatelessWidget {
  final double size;
  const _GroupAvatar({required this.size});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: y.accentSoft, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(Icons.groups_outlined, size: size * 0.5, color: y.accent),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: y.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: y.onPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ===========================================================================
// Thread
// ===========================================================================

class ChatThreadScreen extends ConsumerStatefulWidget {
  final String conversationId;
  final Conversation? initialConversation;
  final Me me;
  const ChatThreadScreen({
    super.key,
    required this.conversationId,
    required this.me,
    this.initialConversation,
  });

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  static const _pageSize = 30;

  final _scroll = ScrollController();
  final _input = TextEditingController();

  List<ChatMessage> _messages = const [];
  Conversation? _conversation;
  bool _initialLoading = true;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;
  bool _sending = false;
  String? _error;
  int _lastMarkedRead = 0;

  @override
  void initState() {
    super.initState();
    _conversation = widget.initialConversation;
    _scroll.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  ApiClient get _api => ref.read(apiClientProvider);

  Future<void> _loadInitial() async {
    try {
      final conv = _conversation;
      // Refresh conversation metadata (members/title) if we arrived without
      // it (e.g. deep link); otherwise the passed-in copy is fine.
      final msgs = await _api.messages(widget.conversationId, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _hasMoreHistory = msgs.length >= _pageSize;
        _initialLoading = false;
        _conversation = conv;
      });
      _markReadToLatest();
      _jumpToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialLoading = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreHistory || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final older = await _api.messages(
        widget.conversationId,
        before: _messages.first.seq,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _messages = [...older, ..._messages];
        _hasMoreHistory = older.length >= _pageSize;
        _loadingOlder = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingOlder = false);
    }
  }

  /// The poll: fetch anything newer than the last message we hold and append.
  Future<void> _pollNew() async {
    if (_messages.isEmpty) {
      // Nothing yet — treat the poll as an initial (re)load.
      await _loadInitial();
      return;
    }
    try {
      final fresh = await _api.messages(
        widget.conversationId,
        after: _messages.last.seq,
      );
      if (!mounted || fresh.isEmpty) return;
      final atBottom = _isNearBottom();
      setState(() => _messages = [..._messages, ...fresh]);
      _markReadToLatest();
      if (atBottom) _jumpToBottom();
    } catch (_) {
      // Transient — the next tick retries.
    }
  }

  void _onScroll() {
    // ListView is reversed, so "older" lives at the max extent.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      _loadOlder();
    }
  }

  bool _isNearBottom() => !_scroll.hasClients || _scroll.position.pixels <= 80;

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _markReadToLatest() {
    if (_messages.isEmpty) return;
    final top = _messages.last.seq;
    if (top <= _lastMarkedRead) return;
    _lastMarkedRead = top;
    // Fire-and-forget; refresh the inbox unread count on success.
    _api
        .markConversationRead(widget.conversationId, top)
        .then((_) {
          if (mounted) ref.invalidate(conversationsProvider);
        })
        .catchError((_) {});
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final msg = await _api.sendMessage(widget.conversationId, text);
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, msg];
        _input.clear();
        _sending = false;
      });
      _lastMarkedRead = msg.seq;
      ref.invalidate(conversationsProvider);
      _jumpToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = "Couldn't send: ${ApiError.fromAny(e).message}";
      });
    }
  }

  Future<void> _editMessage(ChatMessage msg) async {
    final next = await _promptText(
      title: 'Edit message',
      initial: msg.body,
      action: 'Save',
    );
    if (next == null || next.trim().isEmpty || next.trim() == msg.body) return;
    try {
      final updated = await _api.editMessage(
        widget.conversationId,
        msg.id,
        next.trim(),
      );
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final m in _messages) m.id == updated.id ? updated : m,
        ];
      });
      ref.invalidate(conversationsProvider);
    } catch (e) {
      _toast("Couldn't edit: ${ApiError.fromAny(e).message}");
    }
  }

  Future<void> _deleteMessage(ChatMessage msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('This removes the message for everyone.'),
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
    if (ok != true) return;
    try {
      await _api.deleteMessage(widget.conversationId, msg.id);
      if (!mounted) return;
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.id == msg.id)
              ChatMessage(
                id: m.id,
                conversationId: m.conversationId,
                seq: m.seq,
                senderId: m.senderId,
                senderName: m.senderName,
                body: '',
                createdAt: m.createdAt,
                editedAt: m.editedAt,
                deletedAt: DateTime.now(),
                readByCount: m.readByCount,
              )
            else
              m,
        ];
      });
      ref.invalidate(conversationsProvider);
    } catch (e) {
      _toast("Couldn't delete: ${ApiError.fromAny(e).message}");
    }
  }

  void _onLongPressOwn(ChatMessage msg) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                _editMessage(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(msg);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptText({
    required String title,
    required String initial,
    required String action,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final conv = _conversation;
    final title = conv?.displayTitle(widget.me.id) ?? 'Conversation';

    return PollingRefresh(
      surface: PollingSurface.chatThread,
      onPoll: _pollNew,
      child: Scaffold(
        backgroundColor: y.background,
        appBar: AppBar(
          backgroundColor: y.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          foregroundColor: y.text,
          titleSpacing: 0,
          title: Row(
            children: [
              if (conv != null)
                conv.isDm
                    ? YAvatar(
                        name: title,
                        photoUrl: conv.otherMember(widget.me.id)?.photoUrl,
                        size: 34,
                      )
                    : _GroupAvatar(size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                      ),
                    ),
                    if (conv != null && !conv.isDm)
                      Text(
                        '${conv.members.length} members',
                        style: TextStyle(fontSize: 11.5, color: y.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: _buildMessageList(y)),
              if (_error != null)
                Container(
                  width: double.infinity,
                  color: const Color(0x14A33B2E),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFA33B2E),
                      fontSize: 12.5,
                    ),
                  ),
                ),
              _Composer(controller: _input, sending: _sending, onSend: _send),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(YogaTokens y) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'Say hello 👋',
          style: TextStyle(color: y.muted, fontSize: 14),
        ),
      );
    }
    // Reversed so index 0 is the newest message at the visual bottom; this
    // keeps the view pinned to the latest line and makes "scroll up = older".
    final reversed = _messages.reversed.toList();
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemCount: reversed.length + (_hasMoreHistory ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == reversed.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final msg = reversed[i];
        final mine = msg.senderId == widget.me.id;
        final isGroup = !(_conversation?.isDm ?? false);
        return _MessageBubble(
          message: msg,
          mine: mine,
          showSender: isGroup && !mine,
          onLongPress: mine && !msg.isDeleted
              ? () => _onLongPressOwn(msg)
              : null,
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final bool showSender;
  final VoidCallback? onLongPress;
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.showSender,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final bg = mine ? y.primary : y.surface;
    final fg = mine ? y.onPrimary : y.text;
    final meta = mine ? y.onPrimary.withValues(alpha: 0.75) : y.muted;

    final body = message.isDeleted
        ? Text(
            'Message removed',
            style: TextStyle(
              fontSize: 14,
              fontStyle: FontStyle.italic,
              color: fg.withValues(alpha: 0.7),
            ),
          )
        : Text(
            message.body,
            style: TextStyle(fontSize: 14.5, color: fg, height: 1.3),
          );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.76,
          ),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: mine ? null : Border.all(color: y.border),
          ),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (showSender) ...[
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: y.accent,
                  ),
                ),
                const SizedBox(height: 2),
              ],
              body,
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _fmtClock(message.createdAt),
                    style: TextStyle(fontSize: 10.5, color: meta),
                  ),
                  if (message.isEdited) ...[
                    const SizedBox(width: 5),
                    Text(
                      '· edited',
                      style: TextStyle(fontSize: 10.5, color: meta),
                    ),
                  ],
                  if (mine &&
                      !message.isDeleted &&
                      message.readByCount > 0) ...[
                    const SizedBox(width: 5),
                    Icon(Icons.done_all, size: 13, color: meta),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: BoxDecoration(
        color: y.surface,
        border: Border(top: BorderSide(color: y.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Message…',
                filled: true,
                fillColor: y.background,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: y.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: y.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: y.primary),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: sending ? null : onSend,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: sending ? y.muted : y.primary,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: sending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(y.onPrimary),
                      ),
                    )
                  : Icon(Icons.arrow_upward, color: y.onPrimary, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- time formatting ------------------------------------------------------

String _fmtClock(DateTime utc) {
  final t = utc.toLocal();
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ap = t.hour < 12 ? 'am' : 'pm';
  return '$h:$m$ap';
}

String _fmtRelative(DateTime utc) {
  final t = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  final diffDays = today.difference(that).inDays;
  if (diffDays == 0) return _fmtClock(utc);
  if (diffDays == 1) return 'Yesterday';
  if (diffDays < 7) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return wd[t.weekday - 1];
  }
  return '${t.day}/${t.month}';
}
