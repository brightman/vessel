"""Extract media from the user-supplied design; rebuild website copy in HTML."""
from pathlib import Path
import sys, json
sys.path.insert(0, '/tmp/wiselife-reference-tools')
import cv2
import numpy as np
from PIL import Image, ImageFilter, ImageDraw
SOURCE = Path('/Users/karama/Downloads/WiseLife个人AI生态系统官网吗-1.png')
ROOT = Path(__file__).resolve().parents[1]
image = Image.open(SOURCE).convert('RGB')
arr = np.array(image)
manifest = []

def save(name, img, box, note):
    img.save(ROOT/'assets'/name, 'WEBP', quality=98, method=6)
    manifest.append({'file':name,'source_rect':box,'size':list(img.size),'processing':note})

def clean(box, regions, name):
    im = np.array(image.crop(box)); mask = np.zeros(im.shape[:2],np.uint8)
    for x1,y1,x2,y2,mode in regions:
        x1-=box[0];x2-=box[0];y1-=box[1];y2-=box[1]
        if mode=='all':mask[y1:y2,x1:x2]=255
        else:
            area=im[y1:y2,x1:x2]; dark=np.min(area,axis=2)<190
            mask[y1:y2,x1:x2]=np.where(dark,255,0).astype(np.uint8)
    mask=cv2.dilate(mask,np.ones((3,3),np.uint8),iterations=1)
    out=cv2.inpaint(im,mask,6,cv2.INPAINT_TELEA)
    save(name,Image.fromarray(out),list(box),'Website text and controls removed with masked inpainting. Device UI retained.')

clean((0,0,1024,369),[
 (43,3,162,38,'text'),(305,6,642,33,'text'),(768,2,985,38,'all'),
 (48,74,268,93,'text'),(46,101,429,175,'text'),(49,184,433,242,'text'),
 (48,253,423,303,'all'),(49,313,420,349,'text'),
 (764,100,940,152,'all'),(809,153,985,204,'all')], 'hero-landscape.webp')
clean((0,369,1024,717),[
 (356,391,668,418,'text'),(287,421,739,438,'text'),
 (49,495,145,620,'text'),(462,498,577,610,'text'),(903,498,1008,621,'text')], 'ecosystem-scene.webp')
clean((0,717,1024,1024),[
 (44,741,339,770,'text'),(48,778,320,828,'text'),
 (47,838,325,893,'all'),(47,893,327,938,'all'),(47,941,326,989,'all'),
 (894,768,974,800,'all'),(893,857,974,891,'all'),(880,944,974,981,'all')], 'today-scene.webp')
clean((0,1329,1024,1536),[
 (435,1355,604,1373,'text'),(254,1377,935,1407,'text'),(302,1410,891,1434,'text'),
 (313,1440,709,1491,'all'),(340,1499,704,1523,'text')], 'launch-mountains.webp')
# Individual products for the responsive layout: a broad soft edge removes crop seams.
def crop(name, box, fade=0):
    im=image.crop(box)
    if fade:
        im=im.convert('RGBA');w,h=im.size
        xx,yy=np.meshgrid(np.arange(w),np.arange(h));edge=np.minimum.reduce([xx,yy,w-1-xx,h-1-yy])
        alpha=np.clip(edge/fade,0,1)*255;im.putalpha(Image.fromarray(alpha.astype(np.uint8)))
    save(name,im,list(box),'Crop from supplied design'+('; feathered edges' if fade else ''))
crop('watch-product.webp',(145,493,256,705),6)
crop('iphone-product.webp',(298,453,449,710),5)
crop('mac-product.webp',(553,477,922,697),7)
crop('today-phone.webp',(316,721,675,1024),4)
crop('meeting.webp',(694,734,983,818))
crop('activity.webp',(679,822,984,913))
crop('reflection.webp',(664,912,984,1008))
crop('memory-art.webp',(226,1038,356,1150),10)
crop('privacy-art.webp',(557,1044,699,1153),12)
crop('knowledge-art.webp',(875,1077,989,1152),8)
crop('ring-product.webp',(780,1190,816,1231),2)
(ROOT/'assets/source-manifest.json').write_text(json.dumps({'source':str(SOURCE),'source_size':list(image.size),'assets':manifest},indent=2)+'\n')
print('Exported',len(manifest),'assets')
