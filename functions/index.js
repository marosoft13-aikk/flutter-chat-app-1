const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

exports.onMessageCreate = functions.firestore
  .document('conversations/{convId}/messages/{msgId}')
  .onCreate(async (snap, context) => {
    const msg = snap.data();
    const convId = context.params.convId;
    // load conversation to know members
    const convSnap = await admin.firestore().collection('conversations').doc(convId).get();
    if (!convSnap.exists) return null;
    const conv = convSnap.data();
    const members = conv.members || [];
    const senderId = msg.senderId;
    const payload = {
      notification: {
        title: 'New message',
        body: msg.text ? msg.text.substring(0, 100) : 'Image',
      },
      data: {
        conversationId: convId,
        messageId: context.params.msgId,
      },
    };
    // send to each member's FCM tokens except sender
    const tokens = [];
    for (const uid of members) {
      if (uid === senderId) continue;
      const userSnap = await admin.firestore().collection('users').doc(uid).get();
      if (!userSnap.exists) continue;
      const user = userSnap.data();
      if (user && user.fcmTokens) {
        tokens.push(...user.fcmTokens);
      }
    }
    if (tokens.length === 0) return null;
    return admin.messaging().sendToDevice(tokens, payload);
  });