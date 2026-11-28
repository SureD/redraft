// Build alias for the two optional emoji packages. The slash entry and the
// picker are both disabled; an accidental attempt to re-enable them fails closed.
function unavailable(): never { throw new Error("此编辑器未启用表情选择器。"); }
export const EmojiPicker = {};
export const useSkinTone = unavailable;
export const loadFrimousseData = unavailable;
export const searchEmojis = unavailable;
