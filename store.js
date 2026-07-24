/* ══════════════════════════════════════════════════════════════════
   LOCAL STORE
   Everything the app knows about this person, in one place.

   Shaped as a single blob on purpose. Spec 7.2 has a `history` table
   holding a jsonb blob per user for passkey recovery, and this IS
   that blob: when passkeys land, recovery is one upload and one
   download, not a migration.

   A hard truth to design around: Safari deletes localStorage,
   IndexedDB and service worker registrations after SEVEN DAYS with no
   interaction with the site. For an app whose entire identity lives
   locally, that means a user who skips a week comes back as a
   stranger. Two things push back:
     · apps opened from the home screen are exempt, they keep their
       own counter of days used
     · navigator.storage.persist() protects storage where supported,
       and must be asked for on every launch
   Neither is a guarantee, which is exactly why spec 5.2 makes the
   passkey the recovery mechanism. Until then, be honest: this is
   memory, not a vault.
   ══════════════════════════════════════════════════════════════════ */
const STORE_KEY = 'bich.local.v1';

const Store = {
  data: {
    v: 1,
    uid: null,          // supabase users.id, once created
    handle: null,       // "slide tem" — generated once, then permanent
    onboarded: false,
    going: {},          // { shortId: isoTimestamp }
    attended: {},       // { shortId: isoTimestamp } — feeds the graph
    hosting: [],        // shortIds this device published
    theme: null,
    invite: ''
  },

  load() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (raw) Object.assign(this.data, JSON.parse(raw));
    } catch (_) { /* private mode, or storage disabled: run in memory */ }

    // migrate the older loose keys so nobody loses their handle
    try {
      const oldH = localStorage.getItem('bich_handle');
      const oldU = localStorage.getItem('bich_uid');
      const oldT = localStorage.getItem('bich_theme');
      const oldI = localStorage.getItem('bich_invite');
      if (oldH && !this.data.handle) this.data.handle = oldH;
      if (oldU && !this.data.uid)    this.data.uid    = oldU;
      if (oldT && !this.data.theme)  this.data.theme  = oldT;
      if (oldI && !this.data.invite) this.data.invite = oldI;
      ['bich_handle','bich_uid','bich_theme','bich_invite'].forEach(k => localStorage.removeItem(k));
    } catch (_) {}

    return this.data;
  },

  save() {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(this.data)); }
    catch (_) { /* quota or private mode: the session still works */ }
  },

  set(patch) { Object.assign(this.data, patch); this.save(); return this.data; },

  isGoing(id)  { return Boolean(this.data.going[id]); },
  setGoing(id, on) {
    if (on) this.data.going[id] = new Date().toISOString();
    else    delete this.data.going[id];
    this.save();
  },
  markAttended(id) { this.data.attended[id] = new Date().toISOString(); this.save(); },
  addHosting(id)   {
    if (!this.data.hosting.includes(id)) { this.data.hosting.push(id); this.save(); }
  },

  /* Ask the browser to treat this storage as worth keeping. Spec 8.2
     says request it after a meaningful interaction rather than on
     load, because a prompt on arrival gets refused. */
  async requestPersistence() {
    if (!navigator.storage || !navigator.storage.persist) return false;
    try {
      if (await navigator.storage.persisted()) return true;
      return await navigator.storage.persist();
    } catch (_) { return false; }
  }
};

Store.load();
