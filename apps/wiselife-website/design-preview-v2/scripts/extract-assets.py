"""Extract and clean the supplied reference artwork. Requires Pillow, NumPy, OpenCV.

Text and controls are rebuilt in HTML. Product screen contents and handwritten
annotations are intentionally retained as part of the illustrations.
"""
from pathlib import Path
import json
import sys

if Path('/tmp/wiselife-reference-tools').exists():
    sys.path.insert(0, '/tmp/wiselife-reference-tools')
import cv2
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/Users/karama/Downloads/WiseLife：你的私人 AI 生活方式平台.png')
source = Image.open(SOURCE).convert('RGB')
manifest = []

def export(name, image, box, note):
    image.save(ROOT / 'assets' / name, quality=98, method=6)
    manifest.append({'file': name, 'source_rect': box, 'size': list(image.size), 'processing': note})

def scene(name, box, regions, smooth_regions=()):
    arr = np.array(source.crop(box))
    mask = np.zeros(arr.shape[:2], np.uint8)
    for region in regions:
        x1,y1,x2,y2,mode = region
        x1 -= box[0]; x2 -= box[0]; y1 -= box[1]; y2 -= box[1]
        if mode == 'all':
            mask[y1:y2,x1:x2] = 255
        else:
            area = arr[y1:y2,x1:x2]
            dark = np.min(area, axis=2) < 188
            mask[y1:y2,x1:x2] = np.where(dark,255,0)
    mask = cv2.dilate(mask,np.ones((3,3),np.uint8),iterations=1)
    cleaned = cv2.inpaint(arr,mask,7,cv2.INPAINT_TELEA)
    # Blend a small local blur only through the inpainted mask to remove hard seams.
    soft = cv2.GaussianBlur(cleaned,(0,0),2.5)
    blend = cv2.GaussianBlur(mask.astype(np.float32)/255,(0,0),2)[:,:,None]
    cleaned = (cleaned*(1-blend)+soft*blend).astype(np.uint8)
    image = Image.fromarray(cleaned)
    # These areas are defocused walls / sky in the design. Smoothing removes
    # inpainted letter-shaped texture while leaving the subject untouched.
    from PIL import ImageDraw
    for area,radius in smooth_regions:
        local = (area[0]-box[0],area[1]-box[1],area[2]-box[0],area[3]-box[1])
        feather = Image.new('L', image.size, 0)
        ImageDraw.Draw(feather).rectangle(local,fill=255)
        feather = feather.filter(ImageFilter.GaussianBlur(7))
        image = Image.composite(image.filter(ImageFilter.GaussianBlur(radius)),image,feather)
    export(name,image,list(box),'Text and controls removed using local masks and inpainting; device screens and handwriting retained.')
    return image

hero = scene('hero.webp',(0,0,1024,436),[
    (73,9,203,46,'all'),(268,12,641,40,'all'),(787,11,952,42,'all'),
    (76,69,310,82,'text'),(73,88,425,182,'text'),(75,187,604,212,'text'),
    (76,219,408,289,'text'),(77,303,433,341,'all'),
    (131,374,217,418,'text'),(282,372,394,418,'text'),(457,372,550,418,'text'),
    (634,373,771,418,'text'),(835,371,976,418,'text')],
    [((74,67,426,291),8),((133,375,212,418),3),((283,375,395,418),3),((457,375,548,418),3),((635,375,770,418),3),((837,375,975,418),3)])
ecosystem = scene('ecosystem.webp',(0,436,1024,703),[
    (55,467,488,501,'text'),(56,506,463,560,'text'),
    (66,624,150,656,'text'),(171,624,262,656,'text'),(286,624,402,656,'text')],
    [((56,465,485,562),7),((65,624,151,656),4),((171,624,262,656),4),((285,624,403,656),4)])
today = scene('today.webp',(0,703,1024,945),[
    (55,741,518,773,'text'),(57,775,452,829,'text'),
    (56,890,181,925,'text'),(187,890,304,925,'text'),
    (307,890,438,925,'text'),(441,890,560,925,'text')],
    [((55,740,520,830),7),((54,891,556,927),5)])
privacy = scene('privacy.webp',(0,945,1024,1258),[
    (641,956,767,971,'text'),(640,972,974,1033,'text'),(641,1037,990,1105,'text'),
    (689,1107,1000,1251,'text'),
    (116,978,202,1019,'text'),(446,977,549,1018,'text'),
    (109,1177,187,1226,'text'),(466,1180,553,1220,'text')],
    [((641,957,992,1105),6),((691,1106,1001,1252),6),((116,978,201,1017),3),((446,978,549,1017),3),((110,1178,186,1225),3),((467,1181,552,1221),3)])
lifestyle = scene('lifestyle.webp',(0,1258,1024,1414),[
    (40,1284,344,1313,'text'),(40,1315,370,1364,'text'),(42,1371,228,1405,'all'),
    (446,1348,573,1404,'text'),(637,1348,781,1403,'text'),(843,1348,986,1405,'text')],
    [((40,1283,371,1365),6),((445,1347,574,1405),4),((637,1347,782,1404),4),((843,1347,986,1405),4)])
closing = scene('closing.webp',(0,1414,1024,1536),[
    (409,1418,666,1429,'text'),(322,1429,709,1459,'text'),(298,1458,730,1485,'text'),
    (426,1483,599,1514,'all'),(384,1515,645,1529,'text')],
    [((299,1418,730,1531),6)])

def crop(name, base, box, note):
    export(name,base.crop(box),list(box),note)

crop('hero-portrait.webp',hero,(434,34,1024,367),'Crop from cleaned hero, for the mobile layout.')
crop('devices.webp',ecosystem,(425,7,1009,267),'Crop from cleaned ecosystem, for the mobile layout.')
crop('today-phone.webp',today,(574,2,810,242),'Crop from cleaned Today illustration, for the mobile layout.')
crop('privacy-devices.webp',privacy,(28,7,577,304),'Crop from cleaned privacy illustration, for the mobile layout.')
crop('privacy-mobile.webp',source,(28,952,577,1249),'Original privacy illustration with its four in-scene labels, for the mobile layout.')
crop('closing-mobile.webp',closing,(0,0,384,122),'Text-free mountain crop for the responsive footer.')
for name,box in [('work',(391,4,574,84)),('rhythm',(582,4,782,85)),('remember',(789,4,987,85))]:
    crop(name+'.webp',lifestyle,box,'Scene photo for the mobile layout, cropped before the original caption panel.')

for name,box in {
    'trust-lock':(78,367,126,415), 'trust-devices':(226,367,275,415),
    'trust-chip':(400,367,449,415), 'trust-ecosystem':(559,367,630,415),
    'trust-shield':(778,367,828,415),
    'feature-capture':(57,842,109,887), 'feature-insights':(187,842,237,887),
    'feature-actions':(306,842,357,887), 'feature-clarity':(441,842,491,887),
    'scene-work':(398,1348,439,1389), 'scene-rhythm':(588,1348,630,1389),
    'scene-remember':(794,1348,836,1389),
    'privacy-shield':(646,1109,679,1138), 'privacy-lock':(646,1143,679,1174),
    'privacy-chip':(646,1180,679,1211), 'privacy-user':(646,1217,679,1248)
}.items():
    crop(name+'.webp',source,box,'Decorative icon cropped from the reference, for responsive layouts.')

# Extract the supplied mark, retaining the exact design rather than inventing a new logo.
mark = np.array(source.crop((74,10,110,46))).astype(float)
alpha = np.clip((205-np.min(mark,axis=2))/190,0,1)
rgba = np.zeros((36,36,4),np.uint8);rgba[:,:,:3]=[9,17,40];rgba[:,:,3]=(alpha*255).astype(np.uint8)
export('brand-mark.png',Image.fromarray(rgba),(74,10,110,46),'Transparent mark extracted from the user-supplied reference.')
apple = np.array(source.crop((98,311,116,333))).astype(float)
alpha = np.clip((np.min(apple,axis=2)-50)/190,0,1)
rgba = np.ones((22,18,4),np.uint8)*255;rgba[:,:,3]=(alpha*255).astype(np.uint8)
export('apple-mark.png',Image.fromarray(rgba),(98,311,116,333),'White Apple glyph extracted from the button in the reference.')

(ROOT/'assets/source-manifest.json').write_text(json.dumps({'source':str(SOURCE),'source_size':list(source.size),'assets':manifest},ensure_ascii=False,indent=2)+'\n')
source.save(ROOT/'evidence/reference.png')
print(f'Extracted {len(manifest)} assets.')
