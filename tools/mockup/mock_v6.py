# Mockups of EQ Engine 0.3 pages at the car's 1920x720 (density 1.5), following the app's dp sizes.
import sys, math
from PIL import Image, ImageDraw, ImageFont
D = 1.5; W, H = 1920, 720; SB = 90
def dp(v): return v * D
F = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"; FB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"; FM = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
def font(sp, bold=False, mono=False): return ImageFont.truetype(FM if mono else (FB if bold else F), int(sp * D * 0.93))
C = dict(BG=(0,0,0), RAIL=(13,16,20), SURFACE=(24,29,36), SURFACE_HI=(33,39,48), SURFACE_TOP=(43,50,61), OUTLINE=(52,61,73),
         PRIMARY=(79,195,247), ON_PRIMARY=(0,42,60), PC=(13,61,84), ONPC=(196,236,255), ON=(230,234,240), VAR=(156,166,178),
         CURVE=(255,183,77), SEC=(255,183,77), SECC=(78,52,10), OK=(108,214,140), WARN=(255,203,107), ERR=(255,138,128))
def base(sel):
    im = Image.new("RGB", (W, H), C['BG']); g = ImageDraw.Draw(im)
    g.rectangle([0,0,W,SB], fill=(0,0,0)); g.text((40,28), "<     ⌂      ≡                    6:03 PM     Wed, Nov. 18", font=font(19), fill=(210,210,210))
    g.rectangle([0,SB,dp(116),H], fill=C['RAIL'])
    labels = ["EQ","Position","Settings","Status","Lab"]; cx = dp(58); step = min(dp(104), (H - SB - dp(12)) / 5)
    lab = min(dp(17), step*0.21); pillH = min(dp(44), step*0.52)
    for i,l in enumerate(labels):
        top = SB + dp(6) + i*step + (step - (pillH + lab*1.9))/2
        if i == sel: g.rounded_rectangle([cx-dp(36), top, cx+dp(36), top+pillH], pillH/2, fill=C['PC'])
        col = C['ONPC'] if i == sel else C['VAR']
        icon(g, i, cx, top + pillH/2, pillH/dp(44)*1.3, col)
        f = ImageFont.truetype(FB if i == sel else F, int(lab*0.93)); w = g.textlength(l, font=f)
        g.text((cx-w/2, top+pillH+lab*1.35-f.size*0.85), l, font=f, fill=C['ON'] if i == sel else C['VAR'])
    return im, g

def icon(g, i, cx, cy, sc, col):
    d = D * sc; lw = max(2, int(2.2*d))
    L = lambda pts, w=lw: g.line(pts, fill=col, width=w, joint="curve")
    if i == 0:
        for k, kn in enumerate([-4, 4, -1]):
            x = cx + (k-1)*7.5*d; L([(x, cy-10*d), (x, cy+10*d)])
            g.rounded_rectangle([x-4*d, cy+(kn-2.2)*d, x+4*d, cy+(kn+2.2)*d], 1.5*d, fill=col)
    elif i == 1:
        g.rounded_rectangle([cx-7.5*d, cy-11*d, cx+7.5*d, cy+11*d], 5*d, outline=col, width=lw)
        L([(cx-5.5*d, cy-4.5*d), (cx+5.5*d, cy-4.5*d)])
        g.ellipse([cx-3*d-2.6*d, cy+0.5*d-2.6*d, cx-3*d+2.6*d, cy+0.5*d+2.6*d], fill=col)
        g.ellipse([cx-3*d-5.2*d, cy+0.5*d-5.2*d, cx-3*d+5.2*d, cy+0.5*d+5.2*d], outline=col, width=max(1,int(1.6*d)))
    elif i == 2:
        pts = []
        for k in range(32):
            a = k/32*2*math.pi - math.pi/2; q = k % 4; rad = (10.5 if q in (1,2) else 7.8)*d
            pts.append((cx+math.cos(a)*rad, cy+math.sin(a)*rad))
        g.polygon(pts, outline=col, width=max(2,int(2*d)))
        g.ellipse([cx-3.3*d, cy-3.3*d, cx+3.3*d, cy+3.3*d], outline=col, width=max(2,int(2*d)))
    elif i == 3:
        g.rounded_rectangle([cx-11*d, cy-9*d, cx+11*d, cy+9*d], 3.5*d, outline=col, width=max(1,int(1.8*d)))
        L([(cx-8*d, cy+1*d), (cx-4*d, cy+1*d), (cx-1.5*d, cy-5*d), (cx+1.5*d, cy+5*d), (cx+4*d, cy+1*d), (cx+8*d, cy+1*d)])
    elif i == 4:
        L([(cx-3.5*d, cy-10*d), (cx-3.5*d, cy-3*d), (cx-9.5*d, cy+9*d), (cx+9.5*d, cy+9*d), (cx+3.5*d, cy-3*d), (cx+3.5*d, cy-10*d)])
        L([(cx-6*d, cy-10*d), (cx+6*d, cy-10*d)])
        g.polygon([(cx-6.6*d, cy+3.5*d), (cx+6.6*d, cy+3.5*d), (cx+8.6*d, cy+8*d), (cx-8.6*d, cy+8*d)], fill=col)
X0 = dp(116) + dp(20); X1 = W - dp(20); Y0 = SB + dp(10); Y1 = H - dp(10)
def header(g, title, sub, y=Y0):
    g.text((X0, y + dp(2)), title, font=font(24, True), fill=C['ON']); g.text((X0, y + dp(33)), sub, font=font(16), fill=C['VAR'])
def btn(g, x, y, label, style, h=46, right=False):
    f = font(18, True); w = g.textlength(label, font=f) + dp(40)
    if right: x = x - w
    fill = {'filled': C['PRIMARY'], 'tonal': C['PC'], 'outlined': None}[style]
    fg = {'filled': C['ON_PRIMARY'], 'tonal': C['ONPC'], 'outlined': C['PRIMARY']}[style]
    g.rounded_rectangle([x, y, x + w, y + dp(h)], dp(20), fill=fill, outline=C['OUTLINE'] if style == 'outlined' else None, width=2)
    g.text((x + dp(20), y + dp(h)/2 - f.size*0.55), label, font=f, fill=fg); return x, w
def switch(g, cx, cy, on):
    w, h = dp(52), dp(32); l, t = cx - w/2, cy - h/2
    if on: g.rounded_rectangle([l,t,l+w,t+h], h/2, fill=C['PRIMARY']); g.ellipse([l+w-h/2-dp(12), cy-dp(12), l+w-h/2+dp(12), cy+dp(12)], fill=C['ON_PRIMARY'])
    else: g.rounded_rectangle([l,t,l+w,t+h], h/2, fill=C['SURFACE_HI'], outline=C['VAR'], width=3); g.ellipse([l+h/2-dp(8), cy-dp(8), l+h/2+dp(8), cy+dp(8)], fill=C['VAR'])
def wrap(g, text, f, width):
    out, line = [], ""
    for w in text.split(" "):
        t = (line + " " + w).strip()
        if g.textlength(t, font=f) > width and line: out.append(line); line = w
        else: line = t
    if line: out.append(line)
    return out
def card(g, x, y, w, title):
    return [x, y, w, title]
def draw_card(g, x, y, w, h, title):
    g.rounded_rectangle([x, y, x + w, y + h], dp(16), fill=C['SURFACE'])
    if title: g.text((x + dp(18), y + dp(14)), title, font=font(19, True), fill=C['ON'])
    return y + dp(14) + (dp(34) if title else 0)
def row(g, x, y, w, title, sub, kind, on=True, label="Open"):
    f1, f2 = font(18), font(15)
    labels = label.split("|") if kind == 'button' else []
    right = dp(56) if kind == 'switch' else sum(g.textlength(l, font=font(18, True)) + dp(40) for l in labels) + dp(8) * (len(labels) - 1)
    lines = wrap(g, sub, f2, w - right - dp(12)) if sub else []
    hh = max(dp(62 if kind == 'switch' else 56), dp(8) + f1.size*1.25 + dp(4) + len(lines) * f2.size * 1.3)
    ty = y + (hh - (f1.size*1.25 + dp(4) + len(lines)*f2.size*1.3)) / 2
    g.text((x, ty), title, font=f1, fill=C['ON'])
    for i, l in enumerate(lines): g.text((x, ty + f1.size*1.25 + dp(4) + i*f2.size*1.3), l, font=f2, fill=C['VAR'])
    if kind == 'switch': switch(g, x + w - dp(28), y + hh/2, on)
    else:
        bx = x + w
        for l in reversed(labels):
            bx, bw = btn(g, bx, y + hh/2 - dp(23), l, 'tonal', right=True); bx -= dp(8)
    return y + hh, len(lines)
def page_eq(resp, bands, preamp, preset):
    im, g = base(0)
    header(g, "Equalizer", preset + "  ·  Preamp " + ("%+g" % (preamp/100)).replace("+0","0") + " dB")
    switch(g, X1 - dp(34), Y0 + dp(26), True); f = font(18, True); g.text((X1 - dp(68) - g.textlength("EQ", font=f), Y0 + dp(26) - f.size*0.55), "EQ", font=f, fill=C['ON'])
    btn(g, X1 - dp(68) - dp(24) - g.textlength("EQ", font=f), Y0 + dp(2), "Auto preamp", 'outlined', right=True)
    px0, py0 = X0, Y0 + dp(52) + dp(8); pw = X1 - X0; ph = (Y1 - dp(46) - dp(10)) - py0
    g.rounded_rectangle([px0, py0, px0 + pw, py0 + ph], dp(16), fill=C['SURFACE'])
    pad = dp(12); gap = max(dp(16), pw * 0.02); colW = (pw - 2*pad - 2*gap) / 12
    ts = max(dp(16), min(colW * 0.22, ph * 0.06)); sub = ts * 0.82
    valueY = pad + ts*1.1; trackTop = valueY + ts*0.9; sub2Y = ph - pad*0.6; labelY = sub2Y - sub*1.3 - ts; trackBottom = labelY - ts*0.35
    thumbH = max(dp(22), (trackBottom - trackTop)*0.07); trackW = max(dp(6), colW*0.09)
    cl = lambda c: pad + c*colW + (gap if c >= 1 else 0) + (gap if c >= 11 else 0)
    cx = lambda c: cl(c) + colW/2
    def yF(col, v):
        lo, hi = (-1800, 600) if col == 0 else (-1200, 1200)
        return trackTop + thumbH/2 + (hi - v)/(hi - lo)*(trackBottom - trackTop - thumbH)
    P = lambda x, y: (px0 + x, py0 + y)
    fT, fS, fV = ImageFont.truetype(F, int(ts)), ImageFont.truetype(F, int(sub)), ImageFont.truetype(FB, int(ts*1.1))
    def tc(xc, yb, s, f, fill): w = g.textlength(s, font=f); g.text((px0 + xc - w/2, py0 + yb - f.size*0.8), s, font=f, fill=fill)
    for db in range(-12, 13, 6):
        yy = yF(1, db*100); g.line([P(cl(1)-gap*0.4, yy), P(cl(10)+colW+gap*0.4, yy)], fill=C['OUTLINE'] if db == 0 else (36,42,51), width=2)
        s = ("+" if db > 0 else "") + str(db); w = g.textlength(s, font=fS); g.text((px0 + cl(1) - gap*0.15 - w, py0 + yy + ts*0.3 - sub*0.8), s, font=fS, fill=C['VAR'])
    pts = [P(cx(1) + math.log2((20*1000**(k/95))/31.25)*colW, max(trackTop, min(trackBottom, yF(1, v)))) for k, v in enumerate(resp)]
    g.line(pts, fill=C['CURVE'], width=int(dp(2.5)), joint="curve")
    names = ["31","63","125","250","500","1k","2k","4k","8k","16k"]
    for col in range(11):
        v = preamp if col == 0 else bands[col-1]; c0 = cx(col)
        g.rounded_rectangle([P(c0-trackW/2, trackTop), P(c0+trackW/2, trackBottom)], trackW/2, fill=C['SURFACE_TOP'])
        y0, yv = yF(col, 0), yF(col, v)
        g.rounded_rectangle([P(c0-trackW/2, min(y0, yv)), P(c0+trackW/2, max(y0, yv)+0.1)], trackW/2, fill=C['PRIMARY'] if v >= 0 else (55,140,180))
        tw = colW*0.56
        g.rounded_rectangle([P(c0-tw/2, yv-thumbH/2+3), P(c0+tw/2, yv+thumbH/2+3)], thumbH/2, fill=(8,10,13))
        g.rounded_rectangle([P(c0-tw/2, yv-thumbH/2), P(c0+tw/2, yv+thumbH/2)], thumbH/2, fill=C['ON'])
        g.line([P(c0-tw*0.22, yv), P(c0+tw*0.22, yv)], fill=C['OUTLINE'], width=2)
        s = ("+" if v > 0 else "-" if v < 0 else "") + (str(abs(v)//100) + ("" if abs(v)%100 == 0 else "." + str(abs(v)%100//10)))
        tc(c0, valueY, s, fV, C['ON']); tc(c0, labelY + ts, "Preamp" if col == 0 else names[col-1], fT, C['ON']); tc(c0, sub2Y, "-18..+6" if col == 0 else "Hz", fS, C['VAR'])
    c0 = cx(11); mw = colW*0.34
    g.rounded_rectangle([P(c0-mw/2, trackTop), P(c0+mw/2, trackBottom)], mw/2, fill=C['SURFACE_TOP'])
    yy = trackBottom - (-11.8+36)/36*(trackBottom-trackTop); g.rounded_rectangle([P(c0-mw/2, yy), P(c0+mw/2, trackBottom)], mw/2, fill=C['SEC'])
    pk = trackBottom - (-0.1+36)/36*(trackBottom-trackTop); g.line([P(c0-mw/2, pk), P(c0+mw/2, pk)], fill=C['ON'], width=3)
    for db in range(0, -37, -6):
        ty = trackBottom - (db+36)/36*(trackBottom-trackTop); g.text((px0 + c0 + mw/2 + 6, py0 + ty + ts*0.3 - sub*0.8), str(db), font=fS, fill=C['VAR'])
    tc(c0, valueY, "-11.8", fV, C['ON']); tc(c0, labelY + ts, "Output", fT, C['ON']); tc(c0, sub2Y, "avg dBFS", fS, C['VAR'])
    x = X0; y = Y1 - dp(46) + dp(2)
    def chip(gg, x, nm, sel, sec=False, dim=False):
        f = font(17, sel); w = gg.textlength(nm, font=f) + dp(32)
        if sel: gg.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), fill=C['SECC'] if sec else C['PC'])
        else: gg.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), outline=C['OUTLINE'], width=2)
        gg.text((x + dp(16), y + dp(21) - f.size*0.55), nm, font=f, fill=((255,222,176) if sec else C['ONPC']) if sel else (C['VAR'] if dim else C['ON']))
        return x + w + dp(8)
    for k in range(1, 5): x = chip(g, x, "User %d" % k, False, True, dim=k > 2)
    x += dp(6) - dp(8); g.line([(x, y + dp(7)), (x, y + dp(35))], fill=C['OUTLINE'], width=2); x += dp(14)
    # the built-in strip scrolls by itself: draw it on its own layer and fade the right edge
    strip = Image.new("RGB", (int(X1 - x), int(dp(46))), C['BG']); sg = ImageDraw.Draw(strip)
    yo = y; y = 0; sx = 0
    for nm in ["Flat","Rock","Pop","Jazz","Classical","EDM","Hip-Hop","Acoustic","Vocal","Speech","Bass boost","Treble boost","Loudness"]:
        sx = chip(sg, sx, nm, nm == preset)
        if sx > strip.width: break
    fade = int(dp(48))
    for i in range(fade):
        a = (i + 1) / fade
        col = strip.crop((strip.width - fade + i, 0, strip.width - fade + i + 1, strip.height))
        black = Image.new("RGB", col.size, C['BG']); strip.paste(Image.blend(col, black, a), (strip.width - fade + i, 0))
    im.paste(strip, (int(x), int(yo)))
    return im
def page_settings():
    im, g = base(2)
    header(g, "Settings", "Sound processing and EQ Engine itself")
    top = Y0 + dp(52) + dp(10); cw = (X1 - X0 - dp(16)) / 2
    for ci, (title, rows) in enumerate([("Sound", [("Equalizer","Off passes the audio through untouched (bit-exact)",'switch',True),
                                                   ("Clip guard","Catches peaks that boosts push past full scale",'switch',True),
                                                   ("48 kHz output","Android Auto's music without conversion. Checked every time; falls back to 44.1 kHz",'switch',True),
                                                   ("Audio converter","For voice prompts, and for music when the output is at 44.1 kHz",'button',"Lab")]),
                                         ("EQ Engine", [("EQ Engine","Loads at every start. Off = stock audio",'switch',True),
                                                        ("Detailed logging","Logs every change, for troubleshooting",'switch',False),
                                                        ("Restart Android audio","A few seconds of silence. Parked only",'button',"Restart"),
                                                        ("Save to USB","Report: for sharing. All logs: private",'button',"Report|All logs")])]):
        x = X0 + ci * (cw + dp(16))
        # measure
        tmp = Image.new("RGB", (10, 10)); tg = ImageDraw.Draw(tmp); y = 0
        for r in rows: y, _ = row(tg, 0, y, cw - dp(36), r[0], r[1], r[2], r[3] if r[2] == 'switch' else True, r[3] if r[2] != 'switch' else "")
        h = dp(14) + dp(30) + y + dp(12)
        yy = draw_card(g, x, top, cw, h, title)
        for r in rows: yy, _ = row(g, x + dp(18), yy, cw - dp(36), r[0], r[1], r[2], r[3] if r[2] == 'switch' else True, r[3] if r[2] != 'switch' else "")
        bottom = top + h
    f = font(15); g.text((X0 + dp(4), bottom + dp(10)), "Tip: set the car's own Bass, Midrange and Treble to Center (Sound Settings > Tone) so EQ Engine is the only tone control.", font=f, fill=C['VAR'])
    return im, bottom + dp(10) + f.size*1.3
def page_status():
    im, g = base(3)
    header(g, "Status", "What the boot step and the filter report")
    top = Y0 + dp(52) + dp(10); total_w = X1 - X0 - dp(12); gw = total_w * 1.25/2.25; lw = total_w - gw
    th = (Y1 - top - dp(20)) / 3; tw = (gw - dp(10)) / 2
    tiles = [("Boot step","Applied, confirmed","Effects list in place · strikes 0\nUnexpected restarts 0 · service started"),
             ("EQ filter","On all music","Since 19:16:40\nRock, preamp -5 dB"),
             ("Output","48 kHz, unconverted","Link pcm2p measured 48000 frames/s\nOther rates: very high quality"),
             ("Processing","1.9% of real time","0.81 ms per 43 ms buffer (max 0.91 ms)\n48000 Hz stereo, audio flowing"),
             ("Levels","Average -11.8 dBFS","Peaks: in 0.0, out 0.0 dBFS\nArrived clipped 37 · guard -0.2 dB"),
             ("App","Service running","EQ Engine 0.6.4 · log normal\nFilter 310 · processing")]
    for i, (n, v, d) in enumerate(tiles):
        r, c = divmod(i, 2); x = X0 + c*(tw + dp(10)); y = top + r*(th + dp(10))
        g.rounded_rectangle([x, y, x+tw, y+th], dp(14), fill=C['SURFACE'])
        g.text((x+dp(14), y+dp(8)), n, font=font(15), fill=C['VAR']); g.text((x+dp(14), y+dp(8)+dp(22)), v, font=font(21, True), fill=C['ON'])
        for alt in [v] + (["44.1 kHz, very high", "44.1 kHz, high", "44.1 kHz, stock"] if n == "Output" else []):
            if g.textlength(alt, font=font(21, True)) > tw - dp(28): print("tile %s: value too wide: %r" % (n, alt))
        yy = y + dp(8) + dp(22) + dp(32); lines = []
        for part in d.split("\n"):
            w_ = wrap(g, part, font(14.5), tw - dp(28)); lines += [w_[0]]
            if len(w_) > 1: print("tile %s: line cut: %r" % (n, part))
        for k, l in enumerate(lines[:2]): g.text((x+dp(14), yy + k*dp(19)), l, font=font(14.5), fill=C['VAR'])
        need = dp(8) + dp(22) + dp(32) + min(2, len(lines))*dp(19) + dp(6)
        if need > th: print("tile %s too tall: need %.0f px, have %.0f" % (n, need, th))
    x = X0 + gw + dp(12); g.rounded_rectangle([x, top, X1, Y1], dp(16), fill=C['SURFACE'])
    g.text((x+dp(18), top+dp(14)), "Log", font=font(19, True), fill=C['ON']); w = g.textlength("Normal", font=font(15)); g.text((X1-dp(18)-w, top+dp(16)), "Normal", font=font(15), fill=C['VAR'])
    log = ["2026-11-18 18:03:52.412 I preset Rock: eq on, preamp -5, clip guard on,", "  converter high quality, bands 31=+5 63=+4 125=+2 250=-1 ...",
           "2026-11-18 18:02:34.120 I attached to session 0: id 105, control true", "2026-11-18 18:02:29.900 I restarting Android's audio server",
           "2026-11-18 18:02:03.369 I engine started; settings: eq on ...", "2026-11-18 18:00:44.065 I turning EQ Engine back on"]
    for k, l in enumerate(log): g.text((x+dp(18), top+dp(50)+k*dp(19)), l[:52], font=font(13.5, mono=True), fill=C['VAR'])
    return im
def chip(g, x, y, label, sel):
    f = font(17, sel); w = g.textlength(label, font=f) + dp(32)
    if sel: g.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), fill=C['PC'])
    else: g.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), outline=C['OUTLINE'], width=2)
    g.text((x+dp(16), y+dp(21)-f.size*0.6), label, font=f, fill=C['ONPC'] if sel else C['ON']); return w
def page_lab():
    im, g = base(4)
    header(g, "Lab", "Experiments: Hyundai's hidden sound pages, the converter, driver tests and an audio trace")
    top = Y0 + dp(52) + dp(10); gap = dp(16); avail = X1 - X0 - 2*gap
    wts = [1.0, 1.1, 1.0]; ws = [avail*w/sum(wts) for w in wts]; xs = [X0, X0 + ws[0] + gap, X0 + ws[0] + ws[1] + 2*gap]
    tmp = Image.new("RGB", (10, 10)); tg = ImageDraw.Draw(tmp)
    bottoms = []
    x, cw = xs[0], ws[0]
    rows = [("Premium Sound","What the amplifier reports"),("Sound Tuning","Tone, fader and balance"),("Sound defaults","Hyundai's sound reset")]
    note = "Hyundai's own screens, including hidden ones. Changes there stay until you change them back."
    nl = wrap(tg, note, font(15), cw - dp(36)); y = len(nl)*dp(19) + dp(6)
    for r in rows:
        y += dp(8); y, nlines = row(tg, 0, y, cw - dp(36), r[0], r[1], 'button', True, "Open")
    h = dp(14) + dp(34) + y + dp(12); yy = draw_card(g, x, top, cw, h, "Hyundai sound pages")
    for k, l in enumerate(nl): g.text((x+dp(18), yy + k*dp(19)), l, font=font(15), fill=C['VAR'])
    yy += len(nl)*dp(19) + dp(6)
    for r in rows:
        yy += dp(8); yy, nlines = row(g, x+dp(18), yy, cw - dp(36), r[0], r[1], 'button', True, "Open")
        if nlines > 1: print("hyundai row wraps:", r[0])
    bottoms.append(top + h)
    x, cw = xs[1], ws[1]
    def conv(gg, y0):
        y = y0; cx = x + dp(18)
        for lab, sel in [("Stock", False), ("High", False), ("Very high", True)]:
            cx += chip(gg, cx, y, lab, sel) + dp(8)
        if cx - dp(8) > x + cw - dp(18): print("chips overflow by %.0f" % (cx - dp(8) - (x + cw - dp(18))))
        y += dp(42) + dp(8)
        for l in wrap(gg, "Main output at 48 kHz: Android Auto's music is not converted. This converter handles voice prompts and anything not at 48 kHz. In use: EQ Engine's tables, 40 taps a side (audio server, 17:59:53)", font(15), cw - dp(36)):
            gg.text((x+dp(18), y), l, font=font(15), fill=C['VAR']); y += dp(19)
        y += dp(8); gg.line([(x+dp(18), y), (x+cw-dp(18), y)], fill=C['OUTLINE'], width=2); y += dp(2)
        y, _ = row(gg, x+dp(18), y, cw - dp(36), "48 kHz output", "48 kHz: link pcm2p, measured 48000 frames/s", 'button', True, "Settings")
        y, _ = row(gg, x+dp(18), y, cw - dp(36), "Driver watch (test)", "Watching: link pcm2p 48000 Hz, measured 48000 frames/s", 'switch', True)
        return y
    hh = conv(tg, 0) + dp(14) + dp(34) + dp(12)
    yy = draw_card(g, x, top, cw, hh, "Converter and driver"); conv(g, yy); bottoms.append(top + hh)
    x, cw = xs[2], ws[2]
    d = ("Records 120 s of Android's system log and before/after snapshots of the audio system. Change sound settings, "
         "volume or sources while it records. Settings > Save to USB > All logs copies it to the stick with everything else.")
    dl = wrap(tg, d, font(15), cw - dp(36)); h2 = dp(14) + dp(34) + len(dl)*dp(20) + dp(14) + dp(46) + dp(6) + dp(26)*2 + dp(26) + dp(12)
    yy = draw_card(g, x, top, cw, h2, "Audio trace")
    for k, l in enumerate(dl): g.text((x+dp(18), yy + k*dp(20)), l, font=font(15), fill=C['VAR'])
    yy += len(dl)*dp(20) + dp(14); btn(g, x+dp(18), yy, "Record 120 s", 'filled')
    g.text((x+dp(18), yy+dp(54)), "Last trace: 19:20:05 (2026-11-19)", font=font(16), fill=C['VAR'])
    g.text((x+dp(18), yy+dp(54)+dp(28)), "ALSA mixer: 52 controls, 2 cards", font=font(15), fill=C['VAR'])
    bottoms.append(top + h2)
    return im, max(bottoms)

def page_position(posv, delay_ms):
    im, g = base(1)
    header(g, "Listening position", "Times the speakers for one seat by delaying the side that is closer to it")
    top = Y0 + dp(52) + dp(10); total = X1 - X0 - dp(16); cw = total*1.15/2.15; iw = total - cw
    g.rounded_rectangle([X0, top, X0+cw, Y1], dp(16), fill=C['SURFACE'])
    # car view area
    vx0, vy0, vw, vh = X0 + dp(18), top + dp(14), cw - dp(36), (Y1 - dp(12)) - (top + dp(14)) - dp(66)
    labelH = dp(26); Hh = vh - labelH - dp(10); Ww = Hh*0.44; cx = vx0 + vw/2; t0 = vy0 + labelH + (vh - labelH - Hh)/2
    f = font(15); w = g.textlength("FRONT", font=f); g.text((cx-w/2, t0-dp(9)-f.size*0.85), "FRONT", font=f, fill=C['VAR'])
    def R(x0,y0,x1,y1): return [cx+x0*Ww, t0+y0*Hh, cx+x1*Ww, t0+y1*Hh]
    g.rounded_rectangle([cx-Ww/2-0.09*Ww, t0+0.25*Hh, cx-Ww/2+0.02*Ww, t0+0.29*Hh], dp(4), fill=C['SURFACE_TOP'])
    g.rounded_rectangle([cx+Ww/2-0.02*Ww, t0+0.25*Hh, cx+Ww/2+0.09*Ww, t0+0.29*Hh], dp(4), fill=C['SURFACE_TOP'])
    g.rounded_rectangle([cx-Ww/2, t0, cx+Ww/2, t0+Hh], 0.22*Ww, fill=C['SURFACE_HI'], outline=C['OUTLINE'], width=3)
    tz = lambda y0,y1,w0,w1: g.polygon([(cx-w0*Ww/2,t0+y0*Hh),(cx+w0*Ww/2,t0+y0*Hh),(cx+w1*Ww/2,t0+y1*Hh),(cx-w1*Ww/2,t0+y1*Hh)], fill=C['SURFACE_TOP'])
    tz(0.19,0.29,0.66,0.84); tz(0.84,0.91,0.82,0.66)
    g.rounded_rectangle(R(-0.44,0.29,0.44,0.33), dp(3), fill=(28,33,41))
    for sx in (-0.22, 0.22): g.rounded_rectangle(R(sx-0.15,0.37,sx+0.15,0.54), 0.06*Ww, fill=C['SURFACE_TOP'])
    g.rounded_rectangle(R(-0.055,0.36,0.055,0.56), dp(4), fill=(28,33,41))
    g.rounded_rectangle(R(-0.40,0.63,0.40,0.78), 0.06*Ww, fill=C['SURFACE_TOP'])
    sw = cx-0.22*Ww; sy = t0+0.345*Hh; rr = 0.085*Ww; g.ellipse([sw-rr, sy-rr, sw+rr, sy+rr], outline=C['VAR'], width=4)
    hx = cx + posv/100*0.22*Ww; hy = t0 + 0.455*Hh
    spk = [(-0.41,0.285,0.035),(-0.49,0.44,0.06),(-0.49,0.69,0.05),(0.41,0.285,0.035),(0.49,0.44,0.06),(0.49,0.69,0.05)]
    for i,(x,y,rad) in enumerate(spk):
        delayed = (i < 3 and posv < 0) or (i >= 3 and posv > 0)
        sx, syy = cx+x*Ww, t0+y*Hh
        if posv: g.line([(sx,syy),(hx,hy)], fill=(150,110,50) if delayed else (40,95,120), width=2)
        rr = rad*Ww; g.ellipse([sx-rr,syy-rr,sx+rr,syy+rr], fill=C['SEC'] if delayed else C['PRIMARY'])
        rr2 = rr*0.45; g.ellipse([sx-rr2,syy-rr2,sx+rr2,syy+rr2], fill=C['SURFACE_HI'])
    rr = 0.13*Ww; g.ellipse([hx-rr,hy-rr,hx+rr,hy+rr], fill=(70,52,22)); rr = 0.07*Ww; g.ellipse([hx-rr,hy-rr,hx+rr,hy+rr], fill=C['SEC'])
    if posv:
        f = font(15, True); s_ = "+%.1f ms" % delay_ms; w = g.textlength(s_, font=f)
        edge = 0.55*Ww + dp(12); lx = cx - edge - w if posv < 0 else cx + edge
        g.text((lx, t0+0.44*Hh + dp(5) - f.size*0.85), s_, font=f, fill=C['SEC'])
    # slider
    sy0 = Y1 - dp(12) - dp(66); L0 = X0 + dp(18) + dp(40); L1 = X0 + cw - dp(18) - dp(40); yy = sy0 + dp(22)
    xf = lambda v: L0 + (v+100)/200*(L1-L0)
    g.rounded_rectangle([L0, yy-dp(4), L1, yy+dp(4)], dp(4), fill=C['SURFACE_TOP'])
    g.rounded_rectangle([min(xf(0),xf(posv)), yy-dp(4), max(xf(0),xf(posv)), yy+dp(4)], dp(4), fill=C['PRIMARY'])
    for v in (-100,-50,0,50,100): g.ellipse([xf(v)-dp(2.5), yy-dp(2.5), xf(v)+dp(2.5), yy+dp(2.5)], fill=C['VAR'] if v == 0 else C['OUTLINE'])
    g.ellipse([xf(posv)-dp(12), yy-dp(12), xf(posv)+dp(12), yy+dp(12)], fill=C['PRIMARY'])
    for v, nm in ((-100,"Driver"),(0,"Center"),(100,"Passenger")):
        f = font(16); w = g.textlength(nm, font=f); g.text((xf(v)-w/2, yy+dp(34)-f.size*0.85), nm, font=f, fill=C['ON'] if v == posv else C['VAR'])
    # info card
    x = X0 + cw + dp(16); g.rounded_rectangle([x, top, X1, Y1], dp(16), fill=C['SURFACE']); x += dp(18); y = top + dp(14)
    g.text((x, y), "Driver's seat" if posv == -100 else "Center", font=font(26, True), fill=C['SEC']); y += dp(40)
    d = "Left speakers delayed %.2f ms (%.0f cm)" % (delay_ms, delay_ms/1000*343*100)
    for l in wrap(g, d, font(17), iw - dp(36)): g.text((x, y), l, font=font(17), fill=C['ON']); y += dp(22)
    y += dp(10)
    for nm in ("Driver","Center","Passenger"):
        f = font(17, nm == "Driver"); w = g.textlength(nm, font=f) + dp(32)
        if nm == "Driver": g.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), fill=C['PC'])
        else: g.rounded_rectangle([x, y, x+w, y+dp(42)], dp(10), outline=C['OUTLINE'], width=2)
        g.text((x+dp(16), y+dp(21)-f.size*0.55), nm, font=f, fill=C['ONPC'] if nm == "Driver" else C['ON']); x += w + dp(8)
    x = X0 + cw + dp(16) + dp(18); y += dp(52); g.line([(x, y), (X1-dp(18), y)], fill=C['OUTLINE'], width=2); y += dp(12)
    g.text((x, y), "Seat offset", font=font(18), fill=C['ON']); g.text((x, y+dp(27)), "1.7 ms  (58 cm)", font=font(15), fill=C['VAR'])
    bx = X1 - dp(18) - dp(64); g.rounded_rectangle([bx, y, bx+dp(64), y+dp(46)], dp(20), fill=C['PC']); f = font(18, True); g.text((bx+dp(26), y+dp(23)-f.size*0.6), "+", font=f, fill=C['ONPC'])
    bx -= dp(72); g.rounded_rectangle([bx, y, bx+dp(64), y+dp(46)], dp(20), fill=C['PC']); g.text((bx+dp(26), y+dp(23)-f.size*0.6), "\u2212", font=f, fill=C['ONPC'])
    y += dp(58)
    note = "How much farther the far side is from that seat. Tune it by ear from that seat with a centered voice: too much pulls the voice toward the far side, too little leaves it on the near side. Each side's front and rear speakers move together; the car's balance and fader still set the volumes."
    for l in wrap(g, note, font(14), iw - dp(36)): g.text((x, y), l, font=font(14), fill=C['VAR']); y += dp(19)
    print("position info bottom %.0f of %.0f" % (y, Y1))
    return im
resp = [int(v) for v in open(sys.argv[1]).read().split(",")]
out = sys.argv[2]
page_eq(resp, [500,400,200,-100,-200,-100,100,300,400,400], -500, "Rock").save(out + "_eq.png")
im, b = page_settings(); im.save(out + "_settings.png"); print("settings bottom %.0f of %d px" % (b, H - dp(10)))
page_status().save(out + "_status.png")
page_position(-100, 1.7).save(out + "_position.png")
im, b = page_lab(); im.save(out + "_lab.png"); print("lab bottom %.0f of %d px" % (b, H - dp(10)))
