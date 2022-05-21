import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'firebase_chat_core_config.dart';
import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {

  /// Current logged in user in Firebase. Does not update automatically.
  /// Use [FirebaseAuth.authStateChanges] to listen to the state changes.
  MyUser? firebaseUser = FirebaseAuth.instance.currentUser != null ?
  MyUser(uid: FirebaseAuth.instance.currentUser!.uid) : null;

  FirebaseChatCore._privateConstructor() {
    FirebaseAuth.instance.currentUser
        ?.toMyUser()
        .then((myUser) => firebaseUser = myUser);

    FirebaseAuth.instance.authStateChanges().listen((User? user) async {
      firebaseUser = await user?.toMyUser();
    });
  }

  /// Config to set custom names for rooms and users collections. Also
  /// see [FirebaseChatCoreConfig].
  FirebaseChatCoreConfig config = const FirebaseChatCoreConfig(
    null,
    'rooms',
    'users',
  );

  Future<void>Function({
  required String roomId,
  required String message,
  required String userName,
  required List<String> sendTo,
  })? onSendMessage;

  /// Singleton instance
  static final FirebaseChatCore instance =
  FirebaseChatCore._privateConstructor();

  /// Gets proper [FirebaseFirestore] instance
  FirebaseFirestore getFirebaseFirestore() {
    return config.firebaseAppName != null
        ? FirebaseFirestore.instanceFor(
      app: Firebase.app(config.firebaseAppName!),
    )
        : FirebaseFirestore.instance;
  }

  /// Sets custom config to change default names for rooms
  /// and users collections. Also see [FirebaseChatCoreConfig].
  void setConfig(FirebaseChatCoreConfig firebaseChatCoreConfig) {
    config = firebaseChatCoreConfig;
  }

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    if (firebaseUser == null) return Future.error('User does not exist');

    final currentUser = await fetchUser(
      getFirebaseFirestore(),
      firebaseUser!.uid,
      config.usersCollectionName,
    );

    final roomUsers = [types.User.fromJson(currentUser)] + users;

    final room = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .add({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
            (previousValue, user) =>
        {
          ...previousValue,
          user.id: user.role?.toShortString(),
        },
      ),
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(types.User otherUser, {
    Map<String, dynamic>? metadata,
    bool isSupport = false
  }) async {
    MyUser? fu = firebaseUser;

    if (fu == null) return await Future.error('User does not exist');
    if (isSupport && fu.isSupport()) {
      fu = MyUser(uid: "support");
    }
    final query = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('userIds', isEqualTo: [fu.uid, otherUser.id]..sort())
        .get();

    final rooms = await processRoomsQuery(
      fu,
      getFirebaseFirestore(),
      query,
      config.usersCollectionName,
    );

    try {
      return rooms.firstWhere((room) {
        if (room.type == types.RoomType.group) return false;

        final userIds = room.users.map((u) => u.id);
        return userIds.contains(fu!.uid) && userIds.contains(otherUser.id);
      });
    } catch (e) {
      // Do nothing if room does not exist
      // Create a new room instead
    }

    final currentUser = await fetchUser(
      getFirebaseFirestore(),
      fu.uid,
      config.usersCollectionName,
    );

    final users = [types.User.fromJson(currentUser), otherUser];

    final room = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .add({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': types.RoomType.direct.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': users.map((u) => u.id).toList()
        ..sort(),
      'userRoles': null,
    });

    return types.Room(
      id: room.id,
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(types.User user) async {
    await getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .doc(user.id)
        .set({
      'createdAt': FieldValue.serverTimestamp(),
      'firstName': user.firstName,
      'imageUrl': user.imageUrl,
      'lastName': user.lastName,
      'lastSeen': FieldValue.serverTimestamp(),
      'metadata': user.metadata,
      'role': user.role?.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Removes message document
  Future<void> deleteMessage(String roomId, String messageId) async {
    await getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/$roomId/messages')
        .doc(messageId)
        .delete();
  }

  /// Removes room document
  Future<void> deleteRoom(String roomId) async {
    await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .doc(roomId)
        .delete();
  }

  /// Removes [types.User] from `users` collection in Firebase
  Future<void> deleteUserFromFirestore(String userId) async {
    await getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .doc(userId)
        .delete();
  }

  /// Returns a stream of messages from Firebase for a given room
  Stream<List<types.Message>> messages(types.Room room, {
    List<Object?>? endAt,
    List<Object?>? endBefore,
    int? limit,
    List<Object?>? startAfter,
    List<Object?>? startAt,
  }) {
    var query = getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/${room.id}/messages')
        .orderBy('createdAt', descending: true);

    if (endAt != null) {
      query = query.endAt(endAt);
    }

    if (endBefore != null) {
      query = query.endBefore(endBefore);
    }

    if (limit != null) {
      query = query.limit(limit);
    }

    if (startAfter != null) {
      query = query.startAfter(startAfter);
    }

    if (startAt != null) {
      query = query.startAt(startAt);
    }

    return query.snapshots().map(
          (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
              (previousValue, doc) {
            final data = doc.data();
            final author = room.users.firstWhere(
                  (u) => u.id == data['authorId'],
              orElse: () => types.User(id: data['authorId'] as String),
            );

            data['author'] = author.toJson();
            data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
            data['id'] = doc.id;
            data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

            return [...previousValue, types.Message.fromJson(data)];
          },
        );
      },
    );
  }

  /// Returns a stream of changes in a room from Firebase
  Stream<types.Room> room(String roomId) {
    if (firebaseUser == null) return const Stream.empty();
    final fu = MyUser(uid: firebaseUser!.uid);

    return getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .doc(roomId)
        .snapshots()
        .asyncMap(
          (doc) =>
          processRoomDocument(
            doc,
            fu,
            getFirebaseFirestore(),
            config.usersCollectionName,
          ),
    );
  }

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`
  Stream<List<types.Room>> rooms(
      {bool orderByUpdatedAt = false, bool isSupport = false}) {
    MyUser? fu = firebaseUser;
    String userId = "";
    if (fu == null) return const Stream.empty();
    isSupport = isSupport == true && fu.isSupport();
    if (isSupport) {
      userId = "support";
    } else {
      userId = firebaseUser!.uid;
    }
    print("fu for rooms is $fu");
    print("firebaseUser for rooms is $firebaseUser");
    final collection = orderByUpdatedAt
        ? getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('userIds', arrayContains: userId)
        .orderBy('updatedAt', descending: true)
        : getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('userIds', arrayContains: userId);

    return collection.snapshots().asyncMap(
          (query) =>
          processRoomsQuery(
              MyUser(uid: userId),
              getFirebaseFirestore(),
              query,
              config.usersCollectionName, isSupport: isSupport
          ),
    );
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(dynamic partialMessage, String roomId,
      {bool isSupport = false, required String userName,required List<String> sendTo}) async {
    MyUser? fu = firebaseUser;
    String userId = "";
    if (fu == null) return;
    if (isSupport == true && fu.isSupport()) {
      userId = "support";
    } else {
      userId = firebaseUser!.uid;
    }

    String? messageText;
    types.Message? message;

    if (partialMessage is types.PartialCustom) {
      message = types.CustomMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialCustom: partialMessage,
      );
    } else if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      messageText = partialMessage.text;
      message = types.TextMessage.fromPartial(
        author: types.User(id: userId),
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      if (userId == "support") {
        message = message.copyWith(metadata: {"supportId": fu.uid});
      }
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = userId;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();

      await getFirebaseFirestore()
          .collection('${config.roomsCollectionName}/$roomId/messages')
          .add(messageMap);
      if (onSendMessage != null) {
        await onSendMessage!(roomId: roomId,
          message: messageText ?? "",
          userName: userName,
          sendTo :sendTo,
        );
      }
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(types.Message message, String roomId) async {
    if (firebaseUser == null) return;
    if (message.author.id != firebaseUser!.uid) return;

    final messageMap = message.toJson();
    messageMap.removeWhere(
            (key, value) =>
        key == 'author' || key == 'createdAt' || key == 'id');
    messageMap['authorId'] = message.author.id;
    messageMap['updatedAt'] = FieldValue.serverTimestamp();

    await getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/$roomId/messages')
        .doc(message.id)
        .update(messageMap);
  }

  /// Updates a room in the Firestore. Accepts any room.
  /// Room will probably be taken from the [rooms] stream.
  void updateRoom(types.Room room) async {
    if (firebaseUser == null) return;

    final roomMap = room.toJson();
    roomMap.removeWhere((key, value) =>
    key == 'createdAt' ||
        key == 'id' ||
        key == 'lastMessages' ||
        key == 'users');

    if (room.type == types.RoomType.direct) {
      roomMap['imageUrl'] = null;
      roomMap['name'] = null;
    }

    roomMap['lastMessages'] = room.lastMessages?.map((m) {
      final messageMap = m.toJson();

      messageMap.removeWhere((key, value) =>
      key == 'author' ||
          key == 'createdAt' ||
          key == 'id' ||
          key == 'updatedAt');

      messageMap['authorId'] = m.author.id;

      return messageMap;
    }).toList();
    roomMap['updatedAt'] = FieldValue.serverTimestamp();
    roomMap['userIds'] = room.users.map((u) => u.id).toList();

    await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .doc(room.id)
        .update(roomMap);
  }

  /// Returns a stream of all users from Firebase
  Stream<List<types.User>> users() {
    if (firebaseUser == null) return const Stream.empty();
    return getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .snapshots()
        .map(
          (snapshot) =>
          snapshot.docs.fold<List<types.User>>(
            [],
                (previousValue, doc) {
              if (firebaseUser!.uid == doc.id) return previousValue;

              final data = doc.data();

              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
              data['id'] = doc.id;
              data['lastSeen'] = data['lastSeen']?.millisecondsSinceEpoch;
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

              return [...previousValue, types.User.fromJson(data)];
            },
          ),
    );
  }
}
