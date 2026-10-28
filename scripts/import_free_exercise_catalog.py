#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Reproduce the complete source-ID mapping and bundled FitnessCore catalog, offline."""
from pathlib import Path
import argparse, hashlib, json, re, shutil

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SHA256 = '4f6e887b23e88ebcd71d510947bda839dfb7caf6876c2381b0309188ea56b48e'
NAMES = '''45度罗马椅背伸展
45度自行车转体卷腹
45度自行车转体卷腹（来源变式二）
四足跪姿腹股沟拉伸
弹力带辅助引体向上
弹力带俯身反向飞鸟
弹力带髋外展
弹力带髋内收
跪姿单臂弹力带下拉
单臂弹力带前平举
俯身单腿弹力带后踢
弹力带过顶臂屈伸
弹力带俯卧腿弯举
弹力带胯下拉
弹力带阻力下斜仰卧起坐
弹力带坐姿腿屈伸
弹力带坐姿划船
弹力带肩部热身拉伸
弹力带侧屈
弹力带站姿提踵
弹力带站姿卷腹
弹力带站姿腿弯举
弹力带站姿斜向上拉
弹力带站姿后束划船
直背弹力带坐姿划船
弹力带三头下压
杠铃背蹲
杠铃卧推
杠铃翻铃推举
窄握杠铃卧推
杠铃弯举
下斜杠铃卧推
杠铃拖拉弯举
杠铃前平举
杠铃前蹲
上斜杠铃卧推
杠铃弓步蹲
俯卧上斜杠铃弯举
俯身杠铃后束平举
杠铃反向腕弯举
坐姿杠铃颈后推举
杠铃耸肩
站姿背后杠铃腕弯举
杠铃直腿硬拉
反握杠铃划船
宽握杠铃直立划船
战绳
训练凳卷腹
凳上臂屈伸
训练凳辅助引体
瑞士球屈膝仰卧转体
瑜伽桥式
瑜伽桥式（来源变式二）
波比跳
蝴蝶坐姿
窄握高位下拉
绳索交叉反向飞鸟
跪姿绳索卷腹
绳索侧平举（来源双侧变式）
绳索仰卧臂屈伸
单臂绳索弯举
单臂绳索前平举
单臂侧向绳索下拉
单臂绳索侧平举
单臂转体坐姿绳索划船
高位下拉
绳索后束划船
绳索绳把过顶臂屈伸
绳把三头下压
V把坐姿高位划船
站姿绳索卷腹
站姿绳索夹胸
站姿内收绳索弯举
站姿绳索斜向上拉
站姿单臂绳索臂屈伸
绳索直臂下拉
绳索下压
绳索由上向下转体
绳带小腿拉伸
拉伸带小腿拉伸
曲杆俯卧划船
有氧组合动作（来源示范一）
有氧器械动作（来源示范一）
有氧器械动作（来源示范二）
胸部侧重双杠臂屈伸
抬胸转体
低头颈前侧拉伸
窄距中立握引体向上
窄距器械腿举
窄握反手引体向上
窄距俯卧撑
交错握引体向上
交叉跪姿髋屈肌拉伸
下斜哑铃卧推
下斜哑铃飞鸟
加深幅度俯卧撑
驴式提踵
哑铃交替肩上推举
阿诺德哑铃推举
哑铃背后腕弯举
俯身双哑铃划船
哑铃弯举
哑铃窄距卧推
哑铃集中弯举
哑铃交叉锤式弯举
哑铃硬拉
哑铃飞鸟
瑞士球哑铃飞鸟
哑铃前平举
哑铃高脚杯深蹲
上斜凳锤式握哑铃划船
上斜哑铃卧推
上斜哑铃二头弯举（来源变式）
上斜哑铃弯举
上斜哑铃飞鸟
瑞士球上斜哑铃飞鸟
上斜哑铃锤式弯举
上斜哑铃中立握推胸
上斜凳哑铃反向飞鸟
上斜凳哑铃划船
上斜凳哑铃耸肩
上斜哑铃臂屈伸
哑铃十字平举
哑铃俯身臂屈伸
哑铃侧平举
哑铃弓步蹲
哑铃仰卧交替臂屈伸
哑铃仰卧中立握推胸
哑铃仰卧腿弯举
哑铃俯卧后束划船
哑铃仰卧臂屈伸
单臂哑铃侧平举
单臂哑铃佐特曼牧师凳弯举
单臂哑铃过顶臂屈伸
训练凳支撑哑铃腕弯举
转腕俯身哑铃划船
瑞士球哑铃牧师弯举
旋前握哑铃臂屈伸
俯卧上斜哑铃弯举
哑铃后束划船
坐姿哑铃提踵
坐姿哑铃前平举
坐姿哑铃臂屈伸后踢
坐姿哑铃侧平举
坐姿中立握哑铃腕弯举
坐姿哑铃牧师凳弯举
坐姿哑铃过顶臂屈伸
哑铃耸肩
哑铃侧屈
哑铃单腿提踵
哑铃单腿深蹲
哑铃深蹲
站姿哑铃提踵
哑铃直腿硬拉
哑铃相扑深蹲
哑铃直立划船
胸部动态拉伸
椭圆机
瑞士球仰卧起坐
瑞士球脊柱拉伸
EZ杠弯举
曲杆仰卧臂屈伸
EZ杠反重力推举
脚踝绕环拉伸
脚踝伸展
平凳绳索飞鸟
屈腿仰卧起坐拉伸
地面卷腹
前臂平板支撑
站姿触脚尖拉伸
臀桥
悬垂举腿抬髋
悬垂直腿举腿
髋部绕环拉伸
髋伸展拉伸
髋屈肌与股四头肌拉伸
上斜凳举腿抬髋
上斜俯卧撑
双椅间反向划船
吊带反向划船
十字转体拉伸
普拉提折刀式
地面折刀收腹
折刀分腿卷腹
跳绳
跳跃登阶
开合跳（来源低冲击变式）
壶铃硬拉
跪姿背部转体拉伸
跪姿背阔肌拉伸
跪姿肱三头肌拉伸
地雷杆180度转体
举腿卷腹
举腿抬髋
器械背伸展
器械高位划船
水平器械腿举
上斜器械中立握推胸
器械跪姿腿弯举
器械侧平举
坐姿腿屈伸
器械仰卧推胸
俯卧腿弯举
器械牧师凳弯举
器械反向背伸展
器械反向T杠划船
坐姿器械提踵
器械卷腹
器械坐姿臂屈伸
器械坐姿髋外展
器械坐姿髋内收
坐姿腿弯举
器械坐姿反向飞鸟
器械耸肩
器械站姿提踵
器械站姿髋伸展
器械站姿后踢腿
T杠划船
器械肱三头肌伸展
瑞士球仰卧抬髋
仰卧举腿
侧卧股四头肌拉伸
仰卧剪刀腿
仰卧直腿抬腿
药球靠墙仰卧起坐
中背部拉伸
站姿杠铃推举
颈侧拉伸
复古反向臂屈伸
奥蒂斯负重仰卧起坐
过顶胸部拉伸
蝴蝶机夹胸
腓骨肌拉伸
普拉提螺旋式
普拉提百次拍击
弹动侧弓步拉伸
宽握引体向上
引体向上组合（正握与反握）
俯卧撑
后倾下斜桥式
肩后束拉伸
后脚垫高髋屈肌拉伸
弹力带高位夹胸
反向卷腹
反向臂屈伸位拉伸
反握器械高位下拉
反握引体向上
反握绳索高位下拉
吊环高位划船
转体俯卧撑
跑者拉伸
跑步
瑞士球直臂俄罗斯转体
肩胛双杠下沉
坐姿交替哑铃弯举
坐姿俯身背部拉伸
坐姿船式拉伸
V把坐姿绳索划船
宽握坐姿绳索划船
坐姿小腿拉伸
坐姿哑铃肩上推举
坐姿下背部拉伸
坐姿肩部屈曲下沉后缩拉伸
坐姿直臂转体
瑞士球坐姿转体
坐姿直臂转体拉伸
坐姿宽角式连续动作
肩宽握距引体向上
瑞士球侧屈
站姿侧屈拉伸
侧平板支撑
手腕侧向牵拉
单哑铃直腿硬拉
单腿屈膝拉伸
单腿直膝拉伸
仰卧起坐（来源变式一）
仰卧起坐（来源变式二）
45度腿举机提踵
宽距器械腿举
哈克深蹲
史密斯椅式深蹲
史密斯提踵
史密斯硬拉
史密斯腿举
史密斯坐姿肩推
哑铃施法者转体
脊柱前屈拉伸
徒手深蹲
瑞士球腿弯举
瑞士球垫腿卷腹
台阶小腿拉伸
站姿内收肌拉伸
站姿背部转体拉伸
训练凳辅助小腿拉伸
站姿腘绳肌拉伸
站姿髋屈肌与腹部伸展
站姿抱膝拉伸
站姿侧向拉伸
站姿股四头肌拉伸
站姿上举背部转体拉伸
屈臂站姿侧屈拉伸
站姿健腹轮前滚
固定单车
直腿上举卷腹
仰卧哑铃弯举
跑步机跑步
三头侧重双杠臂屈伸
转体卷腹
V字收腹
双杠支撑举腿
波浪步行机
负重伸腿卷腹
负重仰卧转体
负重西斯深蹲
负重站姿弯举
宽握绳索高位下拉
手腕绕环'''.splitlines()

# Deliberately explicit exact-variant map. Ambiguous grips/postures remain separate identities.
EXISTING = {
0:'back-extension',26:'barbell-back-squat',27:'barbell-bench-press',29:'close-grip-barbell-press',
30:'barbell-curl',31:'decline-barbell-press',34:'barbell-front-squat',35:'incline-barbell-press',
36:'barbell-lunge',39:'barbell-reverse-wrist-curl',41:'barbell-shrug',44:'barbell-reverse-row',
46:'battle-rope',55:'close-grip-lat-pulldown',63:'cable-lateral-raise',65:'lat-pulldown',
75:'straight-arm-pulldown',76:'triceps-pushdown',88:'narrow-leg-press',90:'diamond-push-up',
91:'commando-pull-up',93:'decline-dumbbell-press',98:'arnold-press',101:'dumbbell-curl',
102:'dumbbell-close-grip-press',103:'concentration-curl',105:'dumbbell-deadlift',106:'dumbbell-fly',
108:'dumbbell-front-raise',109:'goblet-squat',111:'incline-dumbbell-press',113:'incline-dumbbell-curl',
118:'incline-reverse-fly',123:'triceps-kickback',124:'lateral-raise',125:'dumbbell-lunge',
130:'dumbbell-skullcrusher',139:'dumbbell-rear-delt-row',147:'dumbbell-shrug',148:'dumbbell-side-bend',
157:'elliptical',160:'ez-bar-curl',161:'ez-skullcrusher',167:'crunch',168:'plank',170:'glute-bridge',
177:'incline-push-up',184:'jump-rope',187:'kettlebell-deadlift',199:'machine-lateral-raise',
200:'leg-extension',202:'lying-leg-curl',207:'machine-crunch',211:'seated-leg-curl',
214:'machine-standing-calf-raise',217:'t-bar-row',226:'standing-barbell-overhead-press',231:'pec-deck-fly',
238:'push-up',246:'chin-up',249:'rotational-push-up',251:'running',259:'seated-calf-stretch',
267:'pull-up',270:'side-plank',277:'leg-press-calf-raise',278:'wide-leg-press',279:'hack-squat',
287:'bodyweight-squat',298:'quadriceps-stretch',302:'stationary-cycling',305:'treadmill-running'
}
MUSCLES = {'abdominals':'腹直肌','abductors':'臀中肌','abs':'腹部','adductors':'内收肌群',
'anterior deltoid':'肩前束','biceps':'肱二头肌','calves':'小腿','cardiovascular system':'全身',
'deltoids':'肩部','delts':'肩部','erector spinae':'竖脊肌','erectors':'竖脊肌',
'forearm extensors':'前臂伸肌','forearms':'前臂','full body':'全身','glutes':'臀部',
'gluteus medius':'臀中肌','hamstrings':'腘绳肌','hip flexors':'髋屈肌群','lats':'背阔肌',
'middle back':'背部','neck flexors':'颈前侧肌群','obliques':'腹斜肌','pectorals':'胸部',
'peroneals':'腓骨肌群','posterior deltoid':'肩后束','quadriceps':'股四头肌','quads':'股四头肌',
'rear deltoids':'肩后束','rectus abdominis':'腹直肌','rhomboids':'菱形肌','spinal erectors':'竖脊肌',
'spine':'脊柱周围肌群','sternocleidomastoid':'胸锁乳突肌','thoracic spine':'胸椎周围肌群',
'traps':'斜方肌','triceps':'肱三头肌','upper back':'上背部','upper pectorals':'上胸部',
'gluteus maximus':'臀大肌','gluteus minimus':'臀小肌','tensor fasciae latae':'阔筋膜张肌',
'trapezius':'斜方肌','infraspinatus':'冈下肌','lower back':'下背部','hip flexor':'髋屈肌群',
'rotator cuff':'肩袖肌群','serratus anterior':'前锯肌','rhomboid':'菱形肌','rhoboids':'菱形肌',
'brachialis':'肱肌','brachioradialis':'肱桡肌','core':'核心','soleus':'比目鱼肌',
'gastrocnemius':'腓肠肌','deltoid':'肩部','forearm':'前臂','abs and hip flexors':'腹部及髋屈肌群'}
EQUIPMENT={'band':'弹力带','barbell':'杠铃','body weight':'徒手','cable':'绳索器械',
'dumbbell':'哑铃','ez barbell':'曲杆杠铃','kettlebell':'壶铃','leverage machine':'固定器械',
'rope':'绳索','sled machine':'雪橇式器械','smith machine':'史密斯器械','stability ball':'瑞士球',
'weighted':'外加负重'}

def old_catalog():
    directory=ROOT/'Packages/FitnessCore/Sources/FitnessCore'
    result={}
    for filename in ['ExerciseCatalog.swift','ExpandedExerciseCatalog.swift','MotionExerciseCatalog.swift']:
        for id,name in re.findall(r'Exercise\(id: "([^"]+)", name: "([^"]+)"',(directory/filename).read_text(encoding='utf-8')):
            result[id]=name
    assert len(result)==222
    return result

def pattern(row):
    text=row['name'].lower()
    if 'stretch' in text or 'yoga' in text or 'pose' in text: return '活动与拉伸'
    if row['target']=='cardiovascular system' or 'cardio' in text: return '有氧'
    if any(x in text for x in ['row','pull-up','chin-up','pulldown']): return '拉'
    if any(x in text for x in ['press','push-up','dip']): return '推'
    if any(x in text for x in ['squat','lunge','leg press']): return '蹲与弓步'
    if any(x in text for x in ['deadlift','hip lift','bridge']): return '髋伸展'
    if 'curl' in text: return '屈曲'
    if any(x in text for x in ['crunch','sit-up','twist','plank']): return '躯干控制'
    if 'calf' in text: return '踝跖屈'
    if 'raise' in text or 'fly' in text: return '抬举与外展'
    return '专项动作'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'Data/free-exercise-source.json')
    parser.add_argument('--write',action='store_true')
    args=parser.parse_args()
    raw=args.source.read_bytes()
    assert hashlib.sha256(raw).hexdigest()==EXPECTED_SHA256, 'Source revision differs; review before importing'
    source=json.loads(raw)
    assert len(source)==len(NAMES)==317 and len({r['id'] for r in source})==317
    assert sum(len(r['videos']) for r in source)==593
    old=old_catalog(); names=set(old.values()); output=[]; mapping=[]
    for index,(row,name) in enumerate(zip(source,NAMES)):
        source_id=row['id']; assert re.fullmatch('[a-z0-9-]+',source_id)
        exercise_id='builtin.'+EXISTING[index] if index in EXISTING else 'free-exercise.'+source_id
        is_new=index not in EXISTING
        if not is_new: assert exercise_id in old
        if is_new and name in names: name+='（来源变式·'+source_id+'）'
        if is_new: assert name not in names; names.add(name)
        text=row['name'].lower(); is_stretch='stretch' in text or 'yoga' in text or 'pose' in text
        cardio=row['target']=='cardiovascular system' or 'cardio' in text or text=='battling ropes'
        kind='cardio' if cardio else ('bodyweight' if row['equipment'] in ['body weight','stability ball'] else 'strength')
        metric='cardio' if cardio else ('duration' if is_stretch or 'plank' in text or 'hundred' in text else 'repetitions')
        load='bodyweight' if cardio or kind=='bodyweight' else ('perHand' if row['equipment']=='dumbbell' else 'total')
        if source_id in ['1757','1760','new-dumbbell-sumo-squat']: load='total'
        item=dict(sourceID=source_id,exerciseID=exercise_id,isNew=is_new,name=name,englishName=row['name'],
            kind=kind,metric=metric,equipment=EQUIPMENT[row['equipment']],muscle=MUSCLES[row['target']],
            loadConvention=load,aliases=row['aliases'],secondaryMuscles=[MUSCLES.get(x,'原始标注：'+x) for x in row['secondaryMuscles']],
            movementPattern=pattern(row),difficulty={'beginner':'来源标注·基础','intermediate':'来源标注·进阶','advanced':'来源标注·高阶'}[row['difficulty']],
            steps=row['steps'],commonMistakes=row['commonMistakes'],originalInstructions=row['instructions'],
            formCues=row['formCues'],breathing=row['breathing'],videos=row['videos'],thumbnails=row['thumbnails'],
            sourceURL='https://github.com/luisaraujoc/free-exercise-db-api/blob/main/data/exercises.json',
            metadataLicense='MIT',videoAuthorizationBasis='userConfirmed')
        output.append(item)
        mapping.append(dict(sourceID=source_id,exerciseID=exercise_id,chineseName=name,mappingReview='明确同一动作变式；沿用原稳定ID和原教学。' if not is_new else '独立来源变式；不按相似名称合并，不自动加入AI规则动作池。'))
    document=dict(formatVersion=1,sourceDatasetSHA256=EXPECTED_SHA256,metadataAuthor='Arham Wani',records=output)
    generated=json.dumps(document,ensure_ascii=False,indent=2)+'\n'
    path=ROOT/'Packages/FitnessCore/Sources/FitnessCore/Resources/free-exercise-catalog.json'
    map_path=ROOT/'Data/free-exercise-import-map.json'
    map_text=json.dumps(mapping,ensure_ascii=False,indent=2)+'\n'
    if args.write:
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(generated,encoding='utf-8')
        map_path.write_text(map_text,encoding='utf-8')
        target=ROOT/'Data/free-exercise-source.json'
        if args.source.resolve()!=target.resolve(): target.write_bytes(raw)
    else:
        assert path.read_text(encoding='utf-8')==generated,'Generated core catalog differs'
        assert map_path.read_text(encoding='utf-8')==map_text,'Reviewed mapping differs'
    print(json.dumps(dict(sourceRecords=len(source),videoVariants=sum(len(x['videos']) for x in source),
        mappedExisting=sum(not r['isNew'] for r in output),newMovements=sum(r['isNew'] for r in output),
        totalMovements=222+sum(r['isNew'] for r in output),sourceSHA256=EXPECTED_SHA256)))

if __name__=='__main__': main()
