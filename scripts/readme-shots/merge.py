# 用法：merge.py <区域截图> <单窗截图(带透明圆角)> <输出> <输出宽度点数>
# 区域截图有真实的玻璃透色，单窗截图只取它的透明度当圆角蒙版；缩到 1x，去掉全部元数据。
import sys
from PIL import Image
region = Image.open(sys.argv[1]).convert("RGB")
win = Image.open(sys.argv[2]).convert("RGBA")
if region.size != win.size:
    raise SystemExit(f"size mismatch {region.size} vs {win.size}")
out = region.convert("RGBA")
out.putalpha(win.getchannel("A"))
w = int(sys.argv[4]); h = round(out.height * w / out.width)
out = out.resize((w, h), Image.LANCZOS)
clean = Image.new("RGBA", out.size); clean.putdata(list(out.getdata()))
clean.save(sys.argv[3], optimize=True)
print(sys.argv[3], clean.size)
