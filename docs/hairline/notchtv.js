/**
 * NotchTV: the app's icon standing on the desk, square on to the viewer. A rounded
 * tile, a band just inside its edge, a notch hanging in the top quarter and a
 * play/pause glyph centred in the rest. The closer the pointer comes to the notch,
 * the wider it spreads along the band, as the real notch does on hover; once it is
 * open the notch takes the bright stroke from the glyph. The slider is the reach.
 *
 * The pattern: one continuous value on a spring, a falloff by distance to a fixed
 * point (the notch at rest), and a rest that already shows the whole icon.
 */
const {
  Cam, fit, proj, rrect, hull, poly, open, fillet, clamp, spring, stepS,
  mk, solid, put, pointer, register, disposer,
} = HL;

const SIZE = 100, R_OUT = 22, BAND = 6, THICK = 7, TILT = 12;
const RB = R_OUT - BAND, X = SIZE / 2 - BAND; // the band's inner corners: concentric with the tile's, always
const RT = 0.8, RN = 4; // the notch's corners: where it leaves the band, and at its foot
const HW0 = 13, ND = 11, TOP = SIZE - BAND; // notch half-width at rest, its depth
const WMAX = X - RB - RT - HW0; // its widest spread: up to where the band's corner arcs begin, never into them
/** Points on a circular arc: centre (cu, cz), radius r, from angle a0 to a1 (radians). */
const arc = (cu, cz, r, a0, a1, n) =>
  Array.from({ length: n + 1 }, (_, i) => { const a = a0 + ((a1 - a0) * i) / n; return [cu + r * Math.cos(a), cz + r * Math.sin(a)]; });
const PI = Math.PI;
// The tile is built in its own frame: u across the face, v out of it, z up it. Turned
// 45° against the world the face would meet the camera square on; YAW turns it 20°
// further, so the tile shows its edge and stands in the room. It leans back by TILT.
const YAW = ((45 - 20) * Math.PI) / 180, cy = Math.cos(YAW), sy = Math.sin(YAW);
const W2 = (u, v) => [u * cy + v * sy, v * cy - u * sy];
const at = (u, z, back = 0) => [...W2(u, -(z / SIZE) * TILT - back), z];
/** How open the notch is with the pointer d from it: 1 near, easing to a floor of .1. */
const opening = (d, R) => (d <= 0.3 * R ? 1 : d >= R ? 0.1 : 1 - ((d - 0.3 * R) / (0.7 * R)) * 0.9);

function mount({ stage, svg, read }, value) {
  const bag = disposer();
  const C = Cam(45, 0.5, 2.1);
  const H = SIZE / 2;
  fit(C, [at(-H, 0), at(H, 0), at(-H, SIZE), at(H, SIZE), at(-H, SIZE, THICK), at(H, SIZE, THICK), at(-H, 0, THICK), at(H, 0, THICK)], 200, 166);
  const P = proj(C);
  const F = (u, z, back = 0) => P(...at(u, z, back));
  const face = (pts) => pts.map(([u, z]) => F(u, z));
  let R = value, over = null;

  const g = mk("g", {}, svg);
  // The tile: a slab whose silhouette is the hull of its two faces, its crease the
  // front face a unit inside.
  // Large rounds: 14 steps a corner, or the facets show (rule 09).
  const ring = rrect(-H, 0, H, SIZE, R_OUT, 14), inner = rrect(-H + 1, 1, H - 1, SIZE - 1, R_OUT - 1, 14);
  const tile = solid(g);
  put(tile, {
    sil: poly(hull(ring.map((s) => F(s.u, s.v)).concat(ring.map((s) => F(s.u, s.v, THICK))))),
    crease: poly(inner.map((s) => F(s.u, s.v))),
  });

  // The band's inner edge, which dips round the notch; the notch drawn again on top
  // so it can take the bright stroke; and the play/pause glyph below it.
  const band = mk("path", { class: "nf" }, g);
  const notch = mk("path", { class: "nf" }, g);
  const glyph = mk("path", { class: "nf hi" }, g);
  const cz = (TOP - ND) / 2 + BAND / 2; // the middle of what the notch leaves below it
  const tri = fillet([[-22, cz + 13], [-22, cz - 13], [3, cz]], [3, 3, 3], 8);
  const bars = [rrect(8, cz - 13, 14.5, cz + 13, 2.4, 6), rrect(18.5, cz - 13, 25, cz + 13, 2.4, 6)];
  glyph.setAttribute("d", [poly(face(tri)), ...bars.map((b) => poly(b.map((s) => F(s.u, s.v))))].join(""));

  let drawn = NaN;
  function drawNotch(w) {
    if (w === drawn) return;
    drawn = w;
    const hw = HW0 + w, lo = TOP - ND;
    // Drawn from circular arcs, not fillet(): fillet trims a radius to half its shorter
    // edge, so the top corners would shrink as the notch widens. Counter-clockwise from
    // the bottom left; the notch is the four arcs in the middle.
    const notchPts = [
      ...arc(hw + RT, TOP - RT, RT, PI / 2, PI, 3), ...arc(hw - RN, lo + RN, RN, 0, -PI / 2, 6),
      ...arc(-hw + RN, lo + RN, RN, -PI / 2, -PI, 6), ...arc(-hw - RT, TOP - RT, RT, 0, PI / 2, 3),
    ];
    const edge = [
      ...arc(-X + RB, BAND + RB, RB, PI, 1.5 * PI, 14), ...arc(X - RB, BAND + RB, RB, 1.5 * PI, 2 * PI, 14),
      ...arc(X - RB, TOP - RB, RB, 0, PI / 2, 14), ...notchPts, ...arc(-X + RB, TOP - RB, RB, PI / 2, PI, 14),
    ];
    band.setAttribute("d", poly(face(edge)));
    notch.setAttribute("d", open(face(notchPts)));
  }

  const REST = 0.06 * WMAX;
  const sp = spring(REST, { eps: 0.02 });
  drawNotch(sp.x);
  const N = F(0, TOP - ND / 2); // the notch at rest: the fixed point the pointer is measured from
  const B = register(stage, (dt) => {
    const m = stepS(sp, dt);
    drawNotch(clamp(sp.x, 0, WMAX));
    return m;
  });
  bag.add(B.unregister);

  // Faces of the tile at rest, for naming what is under the pointer.
  const tileBox = face([[-H, 0], [H, SIZE]]);
  function retarget() {
    let chose = false;
    if (!over) { sp.t = REST; read.textContent = "rest"; }
    else {
      const o = opening(Math.hypot(over[0] - N[0], over[1] - N[1]), R);
      sp.t = o * WMAX;
      chose = o >= 0.7;
      const onTile = over[0] > tileBox[0][0] && over[0] < tileBox[1][0] && over[1] < tileBox[0][1] && over[1] > tileBox[1][1];
      read.textContent = chose ? "notch" : onTile ? "play·pause" : "away";
    }
    // One bright mark: the glyph at rest, the notch once the pointer opens it.
    notch.classList.toggle("hi", chose);
    glyph.classList.toggle("hi", !chose);
    B.wake();
  }

  bag.add(pointer(stage, {
    move: (p) => { over = p; retarget(); },
    leave: () => { over = null; retarget(); },
  }));
  bag.add(() => svg.replaceChildren());

  return {
    set: (v) => { R = v; if (over) retarget(); },
    destroy: bag.dispose,
  };
}

hairline({
  name: "notchtv",
  means: "The NotchTV icon: bring the pointer to the notch and it spreads along the band, as the real one does on hover.",
  rules: [1, 3, 4, 9],
  range: [45, 80, 130],
  tour: [[197, 181], [201, 95], [340, 205], null],
  mount,
});
