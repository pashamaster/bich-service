/* ══════════════════════════════════════════════════════════════════
   bich.service — photo pipeline
   pick -> (heic decode) -> exif -> optional crop -> resize -> send

   Order is load bearing. EXIF is read from the untouched bytes before
   anything decodes, crops or re-encodes, because all three destroy it.
   ══════════════════════════════════════════════════════════════════ */

/* 1000 on the long side is not arbitrary. Gemini bills images in 768px
   tiles. A 3:4 flyer at 1000 becomes 750x1000: the short side stays
   under 768, so it costs 2 tiles instead of 4. Going to 1100 doubles
   the bill and reads no better. */
const SEND_MAX_SIDE  = 1000;   // what Gemini sees
const COVER_MAX_SIDE = 1400;   // what gets stored as the cover

/* ── EXIF ─────────────────────────────────────────────────────────
   Works on JPEG and on HEIC: both put a TIFF block in the file, we
   just have to find it. Returns GPS and capture time or null.        */
function findExifTiff(dv){
  // JPEG: APP1 segment
  if (dv.getUint16(0) === 0xFFD8){
    let off = 2;
    while (off < dv.byteLength - 4){
      const marker = dv.getUint16(off);
      if (marker === 0xFFE1){
        if (dv.getUint32(off + 4) === 0x45786966) return off + 10;
        return null;
      }
      if ((marker & 0xFF00) !== 0xFF00) return null;
      off += 2 + dv.getUint16(off + 2);
    }
    return null;
  }
  // HEIC: scan for the Exif\0\0 marker, then the TIFF header after it
  const limit = Math.min(dv.byteLength - 8, 5 * 1024 * 1024);
  for (let i = 0; i < limit; i++){
    if (dv.getUint32(i) === 0x45786966 && dv.getUint16(i + 4) === 0x0000){
      const t = i + 6;
      const bo = dv.getUint16(t);
      if (bo === 0x4949 || bo === 0x4D4D) return t;
    }
  }
  return null;
}

export function readExif(buffer){
  try {
    const dv = new DataView(buffer);
    const tiff = findExifTiff(dv);
    if (tiff == null) return null;

    const little = dv.getUint16(tiff) === 0x4949;
    const u16 = o => dv.getUint16(o, little);
    const u32 = o => dv.getUint32(o, little);

    const ifd0 = tiff + u32(tiff + 4);
    let gpsPtr = 0, exifPtr = 0;
    const n0 = u16(ifd0);
    for (let i = 0; i < n0; i++){
      const e = ifd0 + 2 + i * 12, tag = u16(e);
      if (tag === 0x8825) gpsPtr  = tiff + u32(e + 8);
      if (tag === 0x8769) exifPtr = tiff + u32(e + 8);
    }

    const rat = o => u32(o) / (u32(o + 4) || 1);
    const dms = o => rat(o) + rat(o + 8) / 60 + rat(o + 16) / 3600;
    let lat = null, lng = null, dt = null;

    if (gpsPtr){
      const ng = u16(gpsPtr);
      let latRef = 'N', lngRef = 'E', latO = 0, lngO = 0;
      for (let i = 0; i < ng; i++){
        const e = gpsPtr + 2 + i * 12, tag = u16(e);
        if (tag === 1) latRef = String.fromCharCode(dv.getUint8(e + 8));
        if (tag === 2) latO = tiff + u32(e + 8);
        if (tag === 3) lngRef = String.fromCharCode(dv.getUint8(e + 8));
        if (tag === 4) lngO = tiff + u32(e + 8);
      }
      if (latO && lngO){
        lat = +(dms(latO) * (latRef === 'S' ? -1 : 1)).toFixed(6);
        lng = +(dms(lngO) * (lngRef === 'W' ? -1 : 1)).toFixed(6);
      }
    }
    if (exifPtr){
      const ne = u16(exifPtr);
      for (let i = 0; i < ne; i++){
        const e = exifPtr + 2 + i * 12;
        if (u16(e) === 0x9003){
          let s = '', p = tiff + u32(e + 8);
          for (let k = 0; k < 19; k++) s += String.fromCharCode(dv.getUint8(p + k));
          dt = s;
        }
      }
    }
    return (lat != null || dt) ? { lat, lng, dt } : null;
  } catch(_){ return null; }
}

/* ── decode, HEIC included ────────────────────────────────────────
   Safari decodes HEIC natively, so most iPhone users cost us nothing.
   Everyone else lazy loads a decoder, and only when they actually hit
   a HEIC. No payload for the common case.                            */
let heicLib = null;
async function loadHeicDecoder(){
  if (heicLib) return heicLib;
  const mod = await import('https://cdn.jsdelivr.net/npm/heic-to@1/+esm');
  heicLib = mod;
  return mod;
}

export async function decodeImage(file){
  // try the browser first, whatever the extension claims
  try {
    const bmp = await createImageBitmap(file);
    return { bitmap: bmp, converted: false };
  } catch(_){}

  const looksHeic = /heic|heif/i.test(file.type) || /\.hei[cf]$/i.test(file.name);
  if (!looksHeic) throw new Error('unreadable');

  const { heicTo } = await loadHeicDecoder();
  const jpeg = await heicTo({ blob: file, type: 'image/jpeg', quality: 0.92 });
  const bmp = await createImageBitmap(jpeg);
  return { bitmap: bmp, converted: true };
}

/* ── resize ───────────────────────────────────────────────────────
   The browser's default downscale is fast and slightly mushy, which
   costs us small print. Halving in steps keeps flyer text crisp, and
   it is the same free canvas either way.                             */
function drawScaled(src, sw, sh, dw, dh, sx = 0, sy = 0){
  let cw = sw, ch = sh;
  let cur = document.createElement('canvas');
  cur.width = cw; cur.height = ch;
  cur.getContext('2d').drawImage(src, sx, sy, sw, sh, 0, 0, cw, ch);

  while (cw > dw * 2){
    const nw = Math.max(dw, Math.round(cw / 2));
    const nh = Math.max(dh, Math.round(ch / 2));
    const next = document.createElement('canvas');
    next.width = nw; next.height = nh;
    const cx = next.getContext('2d');
    cx.imageSmoothingEnabled = true;
    cx.imageSmoothingQuality = 'high';
    cx.drawImage(cur, 0, 0, nw, nh);
    cur = next; cw = nw; ch = nh;
  }
  const out = document.createElement('canvas');
  out.width = dw; out.height = dh;
  const ox = out.getContext('2d');
  ox.imageSmoothingEnabled = true;
  ox.imageSmoothingQuality = 'high';
  ox.drawImage(cur, 0, 0, dw, dh);
  return out;
}

let webpOk = null;
function supportsWebp(){
  if (webpOk != null) return webpOk;
  const c = document.createElement('canvas');
  c.width = c.height = 1;
  webpOk = c.toDataURL('image/webp').startsWith('data:image/webp');
  return webpOk;
}

/* crop is {x,y,w,h} in source pixels, or null for the whole image */
export function render(bitmap, crop, maxSide, quality = 0.85){
  const sx = crop ? Math.round(crop.x) : 0;
  const sy = crop ? Math.round(crop.y) : 0;
  const sw = crop ? Math.round(crop.w) : bitmap.width;
  const sh = crop ? Math.round(crop.h) : bitmap.height;

  const scale = Math.min(1, maxSide / Math.max(sw, sh));
  const dw = Math.max(1, Math.round(sw * scale));
  const dh = Math.max(1, Math.round(sh * scale));

  const canvas = drawScaled(bitmap, sw, sh, dw, dh, sx, sy);
  const mime = supportsWebp() ? 'image/webp' : 'image/jpeg';
  const dataUrl = canvas.toDataURL(mime, quality);
  return {
    dataUrl,
    base64: dataUrl.split(',')[1],
    mime,
    width: dw,
    height: dh,
    bytes: Math.round(dataUrl.length * 0.75)
  };
}

/* ── crop UI ──────────────────────────────────────────────────────
   A rectangle over the photo with four corner handles. Drag inside to
   move it, drag a corner to resize. Free form on purpose: a flyer is
   whatever shape it is, and locking a ratio is how you slice off the
   bottom line where the venue lives.

   Touch targets are 44px even though the handles look smaller, and
   touch-action is none so dragging never scrolls the sheet underneath.
   Resolves {x,y,w,h} in source pixels, or null if skipped.            */
export function openCropper(bitmap, opts = {}){
  return new Promise(resolve => {
    const root = document.createElement('div');
    root.className = 'cropper';
    root.innerHTML = `
      <div class="cropper__bar">
        <button class="cropper__btn" data-act="cancel">back</button>
        <span class="cropper__hint">${opts.hint || 'drag the corners to the flyer'}</span>
      </div>
      <div class="cropper__stage"><canvas class="cropper__canvas"></canvas>
        <div class="cropper__shade"></div>
        <div class="cropper__rect">
          <i data-h="nw"></i><i data-h="ne"></i><i data-h="se"></i><i data-h="sw"></i>
        </div>
      </div>
      <div class="cropper__actions">
        <button class="cropper__btn" data-act="skip">use whole photo</button>
        <button class="cropper__btn cropper__btn--go" data-act="ok">use this crop</button>
      </div>`;
    document.body.appendChild(root);

    const stage  = root.querySelector('.cropper__stage');
    const canvas = root.querySelector('.cropper__canvas');
    const rectEl = root.querySelector('.cropper__rect');
    const shade  = root.querySelector('.cropper__shade');

    // fit the photo into the stage
    let view = { x:0, y:0, w:0, h:0, scale:1 };
    function layout(){
      const box = stage.getBoundingClientRect();
      const s = Math.min(box.width / bitmap.width, box.height / bitmap.height);
      view.scale = s;
      view.w = Math.round(bitmap.width * s);
      view.h = Math.round(bitmap.height * s);
      view.x = Math.round((box.width  - view.w) / 2);
      view.y = Math.round((box.height - view.h) / 2);
      canvas.width = view.w; canvas.height = view.h;
      canvas.style.left = view.x + 'px';
      canvas.style.top  = view.y + 'px';
      canvas.getContext('2d').drawImage(bitmap, 0, 0, view.w, view.h);
    }

    // crop rect in *display* pixels, inset a little so handles are visible
    let box = null;
    function initBox(){
      const inset = 0.08;
      box = {
        x: view.x + view.w * inset,
        y: view.y + view.h * inset,
        w: view.w * (1 - inset * 2),
        h: view.h * (1 - inset * 2)
      };
    }
    function paint(){
      rectEl.style.left   = box.x + 'px';
      rectEl.style.top    = box.y + 'px';
      rectEl.style.width  = box.w + 'px';
      rectEl.style.height = box.h + 'px';
      shade.style.clipPath =
        `polygon(0 0, 100% 0, 100% 100%, 0 100%, 0 0,
                 ${box.x}px ${box.y}px,
                 ${box.x}px ${box.y + box.h}px,
                 ${box.x + box.w}px ${box.y + box.h}px,
                 ${box.x + box.w}px ${box.y}px,
                 ${box.x}px ${box.y}px)`;
    }

    let drag = null;
    const MIN = 48;
    function pos(e){
      const b = stage.getBoundingClientRect();
      return { x: e.clientX - b.left, y: e.clientY - b.top };
    }
    function onDown(e){
      const handle = e.target.dataset.h;
      drag = { handle, start: pos(e), box: { ...box } };
      stage.setPointerCapture(e.pointerId);
      e.preventDefault();
    }
    function onMove(e){
      if (!drag) return;
      const p = pos(e);
      const dx = p.x - drag.start.x, dy = p.y - drag.start.y;
      const b = drag.box;
      const L = view.x, T = view.y, R = view.x + view.w, B = view.y + view.h;

      if (!drag.handle){
        box.x = Math.min(Math.max(b.x + dx, L), R - b.w);
        box.y = Math.min(Math.max(b.y + dy, T), B - b.h);
      } else {
        let x1 = b.x, y1 = b.y, x2 = b.x + b.w, y2 = b.y + b.h;
        if (drag.handle.includes('w')) x1 = Math.min(Math.max(b.x + dx, L), x2 - MIN);
        if (drag.handle.includes('e')) x2 = Math.max(Math.min(b.x + b.w + dx, R), x1 + MIN);
        if (drag.handle.includes('n')) y1 = Math.min(Math.max(b.y + dy, T), y2 - MIN);
        if (drag.handle.includes('s')) y2 = Math.max(Math.min(b.y + b.h + dy, B), y1 + MIN);
        box = { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
      }
      paint();
    }
    function onUp(){ drag = null; }

    rectEl.addEventListener('pointerdown', onDown);
    stage.addEventListener('pointermove', onMove);
    stage.addEventListener('pointerup', onUp);
    stage.addEventListener('pointercancel', onUp);

    function finish(result){
      window.removeEventListener('resize', relayout);
      root.remove();
      resolve(result);
    }
    function relayout(){ layout(); initBox(); paint(); }

    root.addEventListener('click', e => {
      const act = e.target.dataset.act;
      if (!act) return;
      if (act === 'cancel') return finish(undefined);   // undefined = abandon
      if (act === 'skip')   return finish(null);        // null = whole photo
      const s = view.scale;
      finish({
        x: (box.x - view.x) / s,
        y: (box.y - view.y) / s,
        w: box.w / s,
        h: box.h / s
      });
    });

    window.addEventListener('resize', relayout);
    requestAnimationFrame(relayout);
  });
}
