#!/usr/bin/env python3
"""Render the README hero using the checked-in FileMCP app icon.

Requires Pillow only for explicitly regenerating this documentation graphic.
Run from the repository root:
    python3 assets/branding/render_readme_hero.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "assets/branding/filemcp-v2"
OUT = BRAND / "readme-hero.png"
S = 2
W, H = 1600, 620
FONT_DIR = Path("/System/Library/Fonts/Supplemental")
SANS = FONT_DIR / "Arial.ttf"
BOLD = FONT_DIR / "Arial Bold.ttf"
BLACK = FONT_DIR / "Arial Black.ttf"

def f(size, weight="regular"):
    path = {"regular": SANS, "bold": BOLD, "black": BLACK}[weight]
    return ImageFont.truetype(str(path), size * S)

def xy(box):
    return tuple(round(v * S) for v in box)

def rounded(draw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(xy(box), radius=radius*S, fill=fill, outline=outline, width=width*S)

def line(draw, points, fill, width=1, joint="curve"):
    draw.line([(int(x*S),int(y*S)) for x,y in points], fill=fill, width=max(1,width*S), joint=joint)

def txt(draw, at, label, size, color, weight="regular", anchor=None):
    draw.text((at[0]*S,at[1]*S), label, font=f(size,weight), fill=color, anchor=anchor,
              stroke_width=0)

def glow(image, bbox, color, blur=70):
    layer = Image.new("RGBA",image.size,(0,0,0,0))
    d = ImageDraw.Draw(layer)
    d.ellipse(xy(bbox),fill=color)
    layer = layer.filter(ImageFilter.GaussianBlur(blur*S))
    image.alpha_composite(layer)

# Deep charcoal background with restrained red and blue ambient light.
im = Image.new("RGBA",(W*S,H*S),(11,14,23,255))
d = ImageDraw.Draw(im)
for y in range(H*S):
    t = y/(H*S)
    r=int(13+4*t);g=int(16+2*t);b=int(25+7*t)
    d.line([(0,y),(W*S,y)],fill=(r,g,b,255),width=1)

glow(im,(980,-170,1740,590),(184,18,57,117),100)
glow(im,(720,220,1400,960),(25,74,157,90),118)
glow(im,(1120,360,1710,970),(214,34,74,66),80)
d = ImageDraw.Draw(im)

# Soft technical grid on the right, gracefully faded.
for x in range(850,1600,38):
    for y in range(56,593,38):
        alpha = int(22*(x-850)/750)
        d.ellipse(xy((x,y,x+1.8,y+1.8)),fill=(189,199,219,alpha))

# Top and bottom accents.
rounded(d,(103,72,143,78),3,(241,62,94,255))
txt(d,(155,63),"LOCAL FILES  /  NATIVE MCP",16,(250,119,142,255),"bold")
txt(d,(104,135),"File",112,(248,250,255,255),"black")
txt(d,(327,135),"MCP",112,(248,250,255,255),"black")
rounded(d,(100,280,199,290),5,(235,45,82,255))

txt(d,(103,322),"Your files. Your MCP.",42,(252,252,255,255),"bold")
txt(d,(104,398),"Connect ChatGPT to your local workspace.",25,(177,188,206,255))
txt(d,(104,431),"Keep the access boundaries in your hands.",25,(177,188,206,255))

# Compact feature line with accessible contrast.
line(d,[(104,531),(758,531)],(77,86,108,110),1)
txt(d,(103,547),"macOS  +  WINDOWS",17,(221,226,237,255),"bold")
rounded(d,(319,556,324,561),3,(237,67,103,255))
txt(d,(343,547),"OPEN SOURCE",17,(221,226,237,255),"bold")
rounded(d,(494,556,499,561),3,(237,67,103,255))
txt(d,(517,547),"LOCAL-FIRST",17,(221,226,237,255),"bold")

# Concentric connector paths behind the app illustration.
for inset,alpha in [(10,54),(44,41),(78,25)]:
    d.arc(xy((863-inset,58-inset,1660+inset,650+inset)), start=190, end=332,
          fill=(236,73,107,alpha), width=2*S)

# Main conceptual product card. Not an application screenshot.
rounded(d,(926,111,1532,532),32,(3,6,14,110))
rounded(d,(915,99,1520,519),32,(26,31,46,255),outline=(80,87,111,245),width=2)
rounded(d,(916,100,1519,172),30,(36,41,57,255))
d.rectangle(xy((917,145,1518,173)),fill=(36,41,57,255))
line(d,[(916,173),(1519,173)],(87,97,118,255),1)
for cx,c in [(949,(249,104,120,255)),(969,(247,190,90,255)),(989,(101,197,147,255))]:
    d.ellipse(xy((cx-5,133,cx+5,143)),fill=c)
txt(d,(1022,125),"FILEMCP  /  WORKSPACE",18,(225,230,241,255),"bold")
rounded(d,(1378,118,1491,156),19,(50,62,73,255),outline=(81,110,103,255))
d.ellipse(xy((1393,133,1403,143)),fill=(95,218,165,255))
txt(d,(1413,127),"READY",15,(196,240,219,255),"bold")

rounded(d,(943,195,1492,487),23,(18,23,38,255),outline=(70,78,100,255))
txt(d,(975,222),"LOCAL WORKSPACE",16,(150,164,192,255),"bold")
txt(d,(975,254),"~/Projects",36,(252,253,255,255),"bold")
txt(d,(975,307),"One directory. Your permission.",19,(163,176,199,255))

# Branded icon tile, sourced from the real app assets.
icon = Image.open(BRAND / "app-icon-512.png").convert("RGBA")
icon = icon.resize((116*S,116*S),Image.Resampling.LANCZOS)
shadow=Image.new("RGBA", im.size, (0,0,0,0))
sh=ImageDraw.Draw(shadow)
rounded(sh,(1324,214,1452,342),31,(0,0,0,140))
im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14*S)))
im.alpha_composite(icon,(1330*S,219*S))

d=ImageDraw.Draw(im)
line(d,[(974,362),(1462,362)],(74,81,103,255),1)

# Capability chips visually encode available and default-disabled actions.
chips=[
    (973,382,1130,451,"FILES","READ + WRITE",(38,46,65,255)),
    (1142,382,1294,451,"GIT","BUILT IN",(38,46,65,255)),
    (1306,382,1462,451,"SHELL","OFF BY DEFAULT",(53,41,54,255)),
]
for x1,y1,x2,y2,name,description,bg in chips:
    rounded(d,(x1,y1,x2,y2),14,bg,outline=(72,82,103,255),width=1)
    txt(d,(x1+16,y1+10),name,16,(253,254,255,255),"bold")
    txt(d,(x1+16,y1+36),description,11,(173,187,212,255),"bold")

# Accent highlights and understated status line.
rounded(d,(978,472,1021,476),2,(240,67,104,255))
txt(d,(1037,462),"CONTROLLED ACCESS VIA MCP",13,(165,177,200,255),"bold")

# Border clipping and export in standard sRGB RGBA.
mask=Image.new("L",im.size,0)
md=ImageDraw.Draw(mask)
md.rounded_rectangle((0,0,W*S-1,H*S-1),radius=32*S,fill=255)
im.putalpha(mask)
im=im.resize((W,H),Image.Resampling.LANCZOS)
im.save(OUT,optimize=True)
print(f"Rendered {OUT.relative_to(ROOT)}  {im.width}x{im.height}")
