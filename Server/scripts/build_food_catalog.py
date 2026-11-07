"""Rebuild the bounded, explicitly selected food catalog from USDA SR Legacy CSV.
Usage: python build_food_catalog.py /path/to/official-sr-legacy.zip
Source: https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
USDA FoodData Central, SR Legacy April 2018; public domain / CC0.
"""
import csv,io,json,sys,zipfile
from pathlib import Path
selected={168930:('rice','熟白米饭（中粒，无额外油）'),171477:('chicken','熟去皮鸡胸肉（烤，无额外酱汁）'),173424:('egg','水煮全蛋'),173423:('fried_egg','煎全蛋（数据库已含常见用油，不再重复加油）'),172476:('tofu','普通豆腐（非油炸）'),169967:('broccoli','水煮西兰花'),170440:('potato','去皮水煮土豆'),173944:('banana','香蕉可食部分'),171688:('apple','带皮苹果可食部分'),171265:('milk','全脂牛奶'),171411:('oil','大豆食用油'),169655:('sugar','白砂糖'),168250:('pork','熟猪里脊瘦肉（烤）'),168919:('noodles','煮熟鸡蛋面（有盐，无额外油）'),170457:('tomato','生番茄'),175168:('salmon','熟养殖大西洋三文鱼（干热）'),174924:('bread','普通白面包'),174277:('soy_sauce','普通酱油（大豆与小麦）'),170391:('bok_choy','水煮小白菜，无盐'),169252:('mushroom','水煮白蘑菇'),171794:('beef','熟碎牛肉（90%瘦，煎熟）'),171284:('yogurt','原味全脂酸奶'),173905:('oatmeal','燕麦粥（水煮，无盐）'),173904:('oats_dry','干燕麦片'),169704:('brown_rice','熟糙米'),168928:('pasta','熟意大利面，无盐无酱'),170394:('carrot','水煮胡萝卜'),168409:('cucumber','带皮生黄瓜'),175180:('shrimp','熟虾可食部分'),168483:('sweet_potato','烤红薯可食部分'),173806:('peanut','无盐干烤花生')}
z=zipfile.ZipFile(sys.argv[1])
def rows(name):return csv.DictReader(io.TextIOWrapper(z.open(next(n for n in z.namelist() if n.endswith('/'+name)))))
foods={int(f['fdc_id']):f for f in rows('food.csv') if int(f['fdc_id']) in selected}
values={i:{} for i in selected}
keys={'1008':'energyKcal','1003':'proteinG','1005':'carbsG','1004':'fatG'}
for n in rows('food_nutrient.csv'):
 i=int(n['fdc_id'])
 if i in selected and n['nutrient_id'] in keys and n['amount']!='':values[i][keys[n['nutrient_id']]]=float(n['amount'])
result=[]
for i,(key,name) in selected.items():
 assert set(values[i])==set(keys.values()),(i,values[i])
 result.append({'id':key,'name':name,'fdc_id':i,'description':foods[i]['description'],'per100g':values[i],'source_url':f'https://fdc.nal.usda.gov/food-details/{i}/nutrients'})
out=Path(__file__).resolve().parents[1]/'food_catalog.json'
out.write_text(json.dumps({'version':'USDA-SR-Legacy-2018-curated-v1','source':'USDA FoodData Central, SR Legacy April 2018. CC0. Generic foods, not brand-specific.','foods':result},ensure_ascii=False,indent=2)+'\n')
print(f'Wrote {len(result)} sourced food records')
