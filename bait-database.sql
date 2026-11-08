-- =====================================================================
--  بيت الطالب الأندلسي — قاعدة البيانات + الخادم (Backend)
--  الواجهة (Frontend): صفحة bait/ على GitHub Pages، تعرض وترسل فقط.
--  الخادم (Backend): دوال على الخادم هنا هي مصدر الحقيقة:
--    حساب السعر، التحقق من البيانات والسعة، حالات الطلب، الصلاحيات، السجل.
--  قاعدة البيانات (Database): PostgreSQL في Supabase (جداول + سياسات وصول).
-- =====================================================================

-- ---------- 1) قاعدة البيانات ----------
create table if not exists public.bait_config(
  id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz default now(), updated_by uuid);
create table if not exists public.bait_bookings(
  id text primary key, ref text unique not null, status text not null default 'new',
  date_from date not null, date_to date not null, phone text not null,
  data jsonb not null, created_at timestamptz default now(), updated_at timestamptz default now());
create index if not exists bait_bookings_dates on public.bait_bookings(date_from, date_to) where status in ('approved','confirmed','checkedin');
create index if not exists bait_bookings_phone on public.bait_bookings(phone, created_at);
create table if not exists public.bait_log(
  id bigserial primary key, booking_id text, action text not null, from_status text, to_status text,
  note text, actor uuid, at timestamptz default now());

-- فريق إدارة بيت الطالب: المالك (مدير المنصة) يدعو الأعضاء ويفعّلهم أو يوقفهم
create table if not exists public.bait_team(
  id bigserial primary key, name text not null, phone text not null unique,
  role text not null default 'manager' check (role in ('manager','staff')),
  status text not null default 'invited' check (status in ('invited','active','disabled')),
  user_id uuid unique, token_hash text, expires_at timestamptz,
  invited_at timestamptz default now(), invited_by uuid, joined_at timestamptz);
alter table public.bait_team enable row level security;
revoke all on public.bait_team from anon, authenticated;

-- دور المستخدم الحالي: owner (مدير المنصة) أو manager (إدارة كاملة) أو staff (الحجوزات فقط)
create or replace function public.bait_role() returns text
language sql stable security definer set search_path=public as $$
  select case when public.is_admin() then 'owner'
    else (select role from public.bait_team where user_id=auth.uid() and status='active') end;
$$;
revoke all on function public.bait_role() from public;
grant execute on function public.bait_role() to authenticated;

alter table public.bait_config enable row level security;
alter table public.bait_bookings enable row level security;
alter table public.bait_log enable row level security;

-- الإعدادات: يقرأها الجميع (أسعار معلنة)، والكتابة من دالة الخادم فقط
drop policy if exists bait_cfg_read on public.bait_config;
create policy bait_cfg_read on public.bait_config for select to anon, authenticated using (true);
drop policy if exists bait_cfg_admin on public.bait_config;
-- الطلبات والسجل: الإدارة تقرأ فقط، وكل تعديل يمر عبر دوال الخادم
drop policy if exists bait_bk_insert on public.bait_bookings;
drop policy if exists bait_bk_admin on public.bait_bookings;
drop policy if exists bait_bk_admin_read on public.bait_bookings;
create policy bait_bk_admin_read on public.bait_bookings for select to authenticated using (public.bait_role() is not null);
drop policy if exists bait_log_admin_read on public.bait_log;
create policy bait_log_admin_read on public.bait_log for select to authenticated using (public.bait_role() in ('owner','manager'));

revoke all on public.bait_config, public.bait_bookings, public.bait_log from anon, authenticated;
grant select on public.bait_config to anon, authenticated;
grant select on public.bait_bookings, public.bait_log to authenticated;

-- ---------- 2) الخادم: دوال مساعدة ----------
create or replace function public.bait_cfg() returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce((select data from public.bait_config where id='main'),'{}'::jsonb);
$$;

create or replace function public.bait_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Riyadh')::date $$;

-- قسم حجز (باقة غرف) من الإعدادات بمفتاحه
create or replace function public.bait_pkg(c jsonb, k text) returns jsonb
language sql immutable as $$
  select p from jsonb_array_elements(case when jsonb_typeof(c->'packages')='array' then c->'packages' else '[]'::jsonb end) p where p->>'key'=k limit 1;
$$;

-- توزيع الغرف: يحدد أرقام الغرف المتاحة للطلب في كامل مدته
create or replace function public.bait_alloc(f jsonb, c jsonb, p_exclude text default null) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare dfrom date := nullif(f->>'from','')::date; dto date := nullif(f->>'to','')::date; allr jsonb := c->'capacity'->'rooms';
  occ int[]; sel int[]; ids int[] := '{}'; need int; s int; r jsonb; t text;
begin
  if dfrom is null or dto is null or dto<=dfrom then return jsonb_build_object('ok',false); end if;
  select coalesce(array_agg(distinct x),'{}') into occ from (
    select (e->>'n')::int as x from public.bait_bookings b, jsonb_array_elements(allr) e
      where b.status in ('approved','confirmed','checkedin') and b.date_from<dto and b.date_to>dfrom and b.id is distinct from p_exclude and b.data->'form'->>'mode'='whole'
    union all
    select v::int from public.bait_bookings b, jsonb_array_elements_text(coalesce(b.data->'rooms'->'ids','[]'::jsonb)) v
      where b.status in ('approved','confirmed','checkedin') and b.date_from<dto and b.date_to>dfrom and b.id is distinct from p_exclude
  ) t2 where x is not null;
  if f->>'mode'='whole' then
    if cardinality(occ)>0 then return jsonb_build_object('ok',false,'busy',to_jsonb(occ)); end if;
    return jsonb_build_object('ok',true,'ids',(select jsonb_agg((e->>'n')::int order by (e->>'n')::int) from jsonb_array_elements(allr) e));
  elsif f->>'mode'='rooms' or public.bait_pkg(c,f->>'mode') is not null then
    select coalesce(array_agg(distinct x::int),'{}') into sel from jsonb_array_elements_text(case when f->>'mode'<>'rooms' then coalesce(public.bait_pkg(c,f->>'mode')->'rooms','[]'::jsonb) when jsonb_typeof(f->'roomIds')='array' then f->'roomIds' else '[]'::jsonb end) x
      where x ~ '^[0-9]+$' and exists(select 1 from jsonb_array_elements(allr) e where (e->>'n')::int=x::int);
    if cardinality(sel)=0 or sel && occ then return jsonb_build_object('ok',false,'busy',to_jsonb(array(select unnest(sel) intersect select unnest(occ)))); end if;
    return jsonb_build_object('ok',true,'ids',to_jsonb(array(select unnest(sel) order by 1)));
  end if;
  -- حسب العدد: أكبر الغرف المتاحة أولاً لكل نوع
  foreach t in array array['st','sup'] loop
    need := coalesce(nullif(f->>(case when t='st' then 'students' else 'supervisors' end),'')::int,0); s := 0;
    while s<need loop
      -- أصغر غرفة تكفي الباقي، وإلا الأكبر
      select e into r from jsonb_array_elements(allr) e where e->>'t'=t and not ((e->>'n')::int = any(occ)) and not ((e->>'n')::int = any(ids))
        order by ((e->>'beds')::int >= need-s) desc, case when (e->>'beds')::int >= need-s then (e->>'beds')::int else -(e->>'beds')::int end, (e->>'n')::int limit 1;
      if r is null then return jsonb_build_object('ok',false); end if;
      ids := ids || (r->>'n')::int; s := s+(r->>'beds')::int; r := null;
    end loop;
  end loop;
  return jsonb_build_object('ok',true,'ids',to_jsonb(array(select unnest(ids) order by 1)));
end $$;

-- عدد غرف كل نوع من قائمة أرقام
create or replace function public.bait_rooms_of(ids jsonb, c jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ids',coalesce(ids,'[]'::jsonb),
    'st',(select count(*) from jsonb_array_elements_text(coalesce(ids,'[]'::jsonb)) x join jsonb_array_elements(c->'capacity'->'rooms') e on (e->>'n')=x where e->>'t'='st'),
    'sup',(select count(*) from jsonb_array_elements_text(coalesce(ids,'[]'::jsonb)) x join jsonb_array_elements(c->'capacity'->'rooms') e on (e->>'n')=x where e->>'t'='sup'));
$$;

-- حساب السعر (مصدر الحقيقة)
create or replace function public.bait_quote(f jsonb, c jsonb, p_created date default null) returns jsonb
language plpgsql stable as $$
declare
  dfrom date := nullif(f->>'from','')::date; dto date := nullif(f->>'to','')::date;
  n int; we int := 0; wd int; dd date; P jsonb := c->'prices';
  L jsonb := '[]'; Ds jsonb := '[]'; acc numeric := 0; addv numeric := 0; v numeric; qty numeric;
  a jsonb; staff boolean := f->>'org'='staff'; internal boolean := f->>'org'='internal'; ops numeric := 0; fac numeric := 0; pct numeric := 0; capped numeric;
  addDisc numeric := 0; accDisc numeric := 0; parts text[] := '{}'; tier jsonb; op numeric;
  code text := upper(trim(coalesce(f->>'promo',''))); pp numeric; lead int;
  sub numeric; vat numeric; vat_on boolean; total numeric; dep numeric;
  lbl text; q1 numeric; key text; pk jsonb;
begin
  if dfrom is null or dto is null or dto<=dfrom then
    return jsonb_build_object('n',0,'L','[]'::jsonb,'D','[]'::jsonb,'total',0,'sub',0,'vat',0,'deposit',0); end if;
  n := dto-dfrom;
  for i in 0..n-1 loop dd := dfrom+i;
    if c->'weekendNights' @> to_jsonb(extract(dow from dd)::int) then we := we+1; end if; end loop;
  wd := n-we;
  -- الإقامة
  for key, lbl, q1 in
    select * from (values
      ('whole','المبنى كاملاً', case when f->>'mode'='whole' then 1 else 0 end),
      ('bedSt','سرير طالب', case when f->>'mode'='beds' then coalesce(nullif(f->>'students','')::numeric,0) else 0 end),
      ('bedSup','سرير مشرف', case when f->>'mode'='beds' then coalesce(nullif(f->>'supervisors','')::numeric,0) else 0 end)
    ) t(k,l,q)
  loop
    if q1>0 then
      v := q1*wd*(P->key->>'wd')::numeric;
      if v>0 then L := L || jsonb_build_array(jsonb_build_array(lbl||': '||q1||' × '||wd||' ليلة وسط الأسبوع × '||(P->key->>'wd')||' ر.س', v)); acc := acc+v; end if;
      v := q1*we*(P->key->>'we')::numeric;
      if v>0 then L := L || jsonb_build_array(jsonb_build_array(lbl||': '||q1||' × '||we||' ليلة نهاية الأسبوع × '||(P->key->>'we')||' ر.س', v)); acc := acc+v; end if;
    end if;
  end loop;
  -- قسم حجز من الإعدادات: سعر ثابت لليلة
  pk := public.bait_pkg(c,f->>'mode');
  if pk is not null then
    v := wd*coalesce((pk->'price'->>'wd')::numeric,0);
    if v>0 then L := L || jsonb_build_array(jsonb_build_array((pk->>'label')||': '||wd||' ليلة وسط الأسبوع', v)); acc := acc+v; end if;
    v := we*coalesce((pk->'price'->>'we')::numeric,0);
    if v>0 then L := L || jsonb_build_array(jsonb_build_array((pk->>'label')||': '||we||' ليلة نهاية الأسبوع', v)); acc := acc+v; end if;
  end if;
  -- حجز غرف محددة: سعر الغرفة = عدد أسرّتها × سعر السرير لنوعها
  if f->>'mode'='rooms' and jsonb_typeof(f->'roomIds')='array' then
    for a in select e from jsonb_array_elements(c->'capacity'->'rooms') e where f->'roomIds' @> to_jsonb((e->>'n')::int) order by (e->>'n')::int loop
      key := case when a->>'t'='st' then 'roomStBed' else 'roomSupBed' end;
      v := (a->>'beds')::numeric*wd*(P->key->>'wd')::numeric;
      if v>0 then L := L || jsonb_build_array(jsonb_build_array('غرفة '||(a->>'n')||': '||wd||' ليلة وسط الأسبوع', v)); acc := acc+v; end if;
      v := (a->>'beds')::numeric*we*(P->key->>'we')::numeric;
      if v>0 then L := L || jsonb_build_array(jsonb_build_array('غرفة '||(a->>'n')||': '||we||' ليلة نهاية الأسبوع', v)); acc := acc+v; end if;
    end loop;
  end if;
  -- المرافق والخدمات
  for a in select * from jsonb_array_elements(c->'addons') loop
    qty := greatest(0,floor(coalesce(nullif(f->'addons'->>(a->>'key'),'')::numeric,0)));
    if qty>0 then v := qty*(a->>'price')::numeric; addv := addv+v;
      L := L || jsonb_build_array(jsonb_build_array((a->>'label')||': '||qty||' '||(a->>'unit')||' × '||(a->>'price')||' ر.س', v)); end if;
  end loop;
  -- الخصومات
  if internal then
    -- برامج داخلية لأقسام الفرع: إعفاء من الإيجار، رسوم تشغيل لكل ليلة، والمرافق مجانية حسب الإعداد
    accDisc := acc;
    if acc>0 then Ds := Ds || jsonb_build_array(jsonb_build_array('إعفاء من رسوم الإيجار للبرامج الداخلية', accDisc)); end if;
    if coalesce((c->'internal'->>'facilitiesFree')::boolean,true) then
      select coalesce(sum(greatest(0,floor(coalesce(nullif(f->'addons'->>(ad->>'key'),'')::numeric,0)))*(ad->>'price')::numeric),0) into fac
        from jsonb_array_elements(c->'addons') ad where ad->>'group'='المرافق';
      if fac>0 then addDisc := fac; Ds := Ds || jsonb_build_array(jsonb_build_array('إعفاء من رسوم المرافق للبرامج الداخلية', fac)); end if;
    end if;
    for a in select * from jsonb_array_elements(coalesce(c->'internal'->'ops','[]'::jsonb)) loop
      v := (a->>'price')::numeric*n;
      if v>0 then ops := ops+v; L := L || jsonb_build_array(jsonb_build_array((a->>'label')||': '||n||' ليلة', v)); end if;
    end loop;
  elsif staff then
    pct := coalesce((c->'orgDisc'->>'staff')::numeric,0); accDisc := acc*pct/100;
    if pct>0 then Ds := Ds || jsonb_build_array(jsonb_build_array('خصم منسوبي شركة الأندلس '||pct||'% على الإقامة', accDisc)); end if;
    if coalesce((c->>'staffAddons')::boolean,true) and addv>0 and pct>0 then addDisc := addv*pct/100;
      Ds := Ds || jsonb_build_array(jsonb_build_array('خصم منسوبي شركة الأندلس '||pct||'% على المرافق والخدمات', addDisc)); end if;
  else
    if f->>'mode'='whole' and addv>0 and coalesce((c->>'wholeAddonDisc')::numeric,0)>0 then
      addDisc := addv*(c->>'wholeAddonDisc')::numeric/100;
      Ds := Ds || jsonb_build_array(jsonb_build_array('خصم الباقة الكاملة على المرافق والخدمات '||(c->>'wholeAddonDisc')||'%', addDisc)); end if;
    select t into tier from jsonb_array_elements(c->'durationTiers') t where (t->>'nights')::int<=n order by (t->>'nights')::int desc limit 1;
    if tier is not null then pct := pct+(tier->>'pct')::numeric; parts := parts || ('إقامة '||(tier->>'nights')||' ليالٍ فأكثر '||(tier->>'pct')||'%'); end if;
    op := coalesce((c->'orgDisc'->>(f->>'org'))::numeric,0);
    if op>0 then pct := pct+op; parts := parts || ('خصم نوع الجهة '||op||'%'); end if;
    lead := dfrom - coalesce(p_created, public.bait_today());
    if lead>=(c->>'earlyDays')::int and coalesce((c->>'earlyPct')::numeric,0)>0 then pct := pct+(c->>'earlyPct')::numeric; parts := parts || ('حجز مبكر '||(c->>'earlyPct')||'%'); end if;
    pp := case when code<>'' then (c->'promos'->>code)::numeric end;
    if pp>0 then pct := pct+pp; parts := parts || ('كود '||code||' '||pp||'%'); end if;
    capped := least(pct,(c->>'maxDisc')::numeric); accDisc := acc*capped/100;
    if capped>0 then Ds := Ds || jsonb_build_array(jsonb_build_array('خصم الإقامة '||capped||'%: '||array_to_string(parts,'، '), accDisc)); end if;
    pct := capped;
  end if;
  sub := round(acc+addv+ops-addDisc-accDisc,2);
  vat_on := not internal and not (staff and not coalesce((c->>'staffVat')::boolean,true));
  vat := case when vat_on then round(sub*(c->>'vat')::numeric/100,2) else 0 end;
  total := sub+vat; dep := case when internal then 0 else round(total*(c->>'depositPct')::numeric/100,2) end;
  return jsonb_build_object('n',n,'we',we,'wd',wd,'L',L,'D',Ds,'acc',acc,'addons',addv,'disc',round(addDisc+accDisc,2),
    'sub',sub,'vat',vat,'vatOn',vat_on,'total',total,'deposit',dep,'ops',ops,'internal',internal,
    'insurance',case when internal then coalesce((c->'internal'->>'insurance')::numeric,2000) else (c->>'insurance')::numeric end,'discPct',pct,'server',true);
end $$;

drop function if exists public.bait_conflicts(jsonb,jsonb,text);
drop function if exists public.bait_rooms(jsonb,jsonb);

-- التحقق من الطلب
create or replace function public.bait_validate(f jsonb, c jsonb) returns text[]
language plpgsql stable security definer set search_path=public as $$
declare E text[] := '{}'; cap jsonb := c->'capacity'; dfrom date; dto date; n int;
  st int := coalesce(nullif(f->>'students','')::int,0); sup int := coalesce(nullif(f->>'supervisors','')::int,0);
  maxst int; maxsup int; ratio int := greatest(1,coalesce((c->>'ratio')::int,15)); al jsonb; nsel int;
begin
  begin dfrom := nullif(f->>'from','')::date; dto := nullif(f->>'to','')::date; exception when others then dfrom := null; end;
  if f->>'mode' not in ('whole','rooms','beds') and coalesce((public.bait_pkg(c,f->>'mode')->>'active')::boolean,public.bait_pkg(c,f->>'mode') is not null) is not true then E := E||'طريقة التأجير غير صحيحة أو الباقة غير متاحة حالياً.'::text; end if;
  if f->>'org' is null or not (c->'orgDisc' ? (f->>'org')) then E := E||'نوع الجهة غير صحيح.'::text; end if;
  if dfrom is null or dto is null then return E||'حدّد تاريخ الوصول وتاريخ المغادرة.'::text; end if;
  n := dto-dfrom;
  if n<1 then E := E||'تاريخ المغادرة يجب أن يكون بعد تاريخ الوصول.'::text;
  elsif n>(c->>'maxNights')::int then E := E||('أقصى مدة للحجز الواحد '||(c->>'maxNights')||' ليلة.'); end if;
  if dfrom<public.bait_today() then E := E||'تاريخ الوصول مضى. اختر تاريخاً قادماً.'::text; end if;
  if st<0 or sup<0 then E := E||'الأعداد لا تكون سالبة.'::text; end if;
  if st+sup<=0 then E := E||'اكتب عدد الطلاب والمشرفين.'::text; end if;
  select coalesce(sum((rm->>'beds')::int) filter (where rm->>'t'='st'),0), coalesce(sum((rm->>'beds')::int) filter (where rm->>'t'='sup'),0), count(*)
    into maxst, maxsup, nsel from jsonb_array_elements(cap->'rooms') rm
    where (f->>'mode' in ('whole','beds'))
       or (f->>'mode'='rooms' and jsonb_typeof(f->'roomIds')='array' and f->'roomIds' @> to_jsonb((rm->>'n')::int))
       or (f->>'mode' not in ('whole','beds','rooms') and coalesce(public.bait_pkg(c,f->>'mode')->'rooms','[]'::jsonb) @> to_jsonb((rm->>'n')::int));
  if f->>'mode'='rooms' and nsel=0 then E := E||'اختر الغرف المطلوبة.'::text; end if;
  if st>maxst then E := E||('عدد الطلاب أكبر من أسرّة الغرف ('||maxst||').'); end if;
  if sup>maxsup then E := E||('عدد المشرفين أكبر من أسرّة غرف المشرفين ('||maxsup||').'); end if;
  if st>0 and sup<ceil(st::numeric/ratio) then E := E||('يلزم مشرف واحد على الأقل لكل '||ratio||' طالباً.'); end if;
  if coalesce(trim(f->>'orgName'),'')='' then E := E||(case when f->>'org'='internal' then 'اكتب اسم القسم المنظّم للبرنامج.' else 'اكتب اسم الجهة.' end); end if;
  if coalesce(trim(f->>'contact'),'')='' then E := E||'اكتب اسم المسؤول.'::text; end if;
  if f->>'org'='staff' and coalesce(trim(f->>'empNo'),'')='' then E := E||'اكتب الرقم الوظيفي لتطبيق خصم المنسوبين.'::text; end if;
  if coalesce(f->>'phone','') !~ '^05[0-9]{8}$' then E := E||'اكتب رقم جوال سعودي صحيح يبدأ بـ 05 ومن 10 أرقام.'::text; end if;
  if coalesce(f->>'email','')<>'' and f->>'email' !~ '^\S+@\S+\.\S+$' then E := E||'البريد الإلكتروني غير صحيح.'::text; end if;
  if coalesce((f->>'agree')::boolean,false) is not true then E := E||'وافق على الشروط والسياسات لإرسال الطلب.'::text; end if;
  if length(f::text)>8000 then E := E||'بيانات الطلب أطول من المسموح.'::text; end if;
  if array_length(E,1) is null then
    al := public.bait_alloc(f,c,null);
    if not (al->>'ok')::boolean then E := E||'لا توجد غرف متاحة كافية في التواريخ المختارة. اختر تواريخ أو غرفاً أخرى.'::text; end if;
  end if;
  return E;
end $$;

-- ---------- 3) الخادم: الدوال التي تستدعيها الواجهة ----------
-- عرض سعر من الخادم (للمعاينة قبل الإرسال)
create or replace function public.bait_price(p_form jsonb) returns jsonb
language sql stable security definer set search_path=public as $$
  select public.bait_quote(p_form, public.bait_cfg(), null);
$$;

-- إرسال طلب حجز: الخادم يتحقق ويحسب السعر ويولّد رقم الطلب
create or replace function public.bait_submit(p_form jsonb) returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare c jsonb := public.bait_cfg(); f jsonb; E text[]; q jsonb; r jsonb; vid text; vref text; ph text; cnt int;
begin
  ph := regexp_replace(regexp_replace(coalesce(p_form->>'phone',''),'[^0-9]','','g'),'^966','0');
  -- نأخذ الحقول المعروفة فقط
  f := jsonb_build_object('from',p_form->>'from','to',p_form->>'to','mode',p_form->>'mode',
    'roomIds',case when jsonb_typeof(p_form->'roomIds')='array' then p_form->'roomIds' else '[]'::jsonb end,'students',p_form->'students','supervisors',p_form->'supervisors',
    'addons',coalesce((select jsonb_object_agg(k,v) from jsonb_each(case when jsonb_typeof(p_form->'addons')='object' then p_form->'addons' else '{}'::jsonb end) e(k,v)
       where exists(select 1 from jsonb_array_elements(c->'addons') a where a->>'key'=k) and jsonb_typeof(v)='number' and v::numeric>0),'{}'::jsonb),
    'org',p_form->>'org','orgName',left(p_form->>'orgName',150),'empNo',left(p_form->>'empNo',40),'contact',left(p_form->>'contact',120),
    'phone',ph,'email',left(p_form->>'email',150),'gender',left(p_form->>'gender',40),'age',left(p_form->>'age',80),
    'purpose',left(p_form->>'purpose',300),'promo',case when p_form->>'org' in ('staff','internal') then '' else left(p_form->>'promo',30) end,
    'notes',left(p_form->>'notes',1000),'agree',coalesce((p_form->>'agree')::boolean,false),'created',public.bait_today());
  -- حماية من الإرسال المتكرر
  select count(*) into cnt from public.bait_bookings where phone=ph and created_at>now()-interval '1 day';
  if cnt>=5 then return jsonb_build_object('ok',false,'errors',jsonb_build_array('وصل عدد الطلبات من هذا الجوال للحد اليومي. تواصل مع الإدارة.')); end if;
  select count(*) into cnt from public.bait_bookings where created_at>now()-interval '1 hour';
  if cnt>=60 then return jsonb_build_object('ok',false,'errors',jsonb_build_array('النظام مشغول الآن. حاول بعد قليل.')); end if;
  E := public.bait_validate(f,c);
  if array_length(E,1)>0 then return jsonb_build_object('ok',false,'errors',to_jsonb(E)); end if;
  q := public.bait_quote(f,c,public.bait_today());
  vid := 'b'||replace(gen_random_uuid()::text,'-','');
  loop
    vref := 'BT-'||to_char(public.bait_today(),'YYMMDD')||'-'||upper(substr(md5(random()::text),1,4));
    exit when not exists(select 1 from public.bait_bookings where ref=vref);
  end loop;
  r := jsonb_build_object('id',vid,'ref',vref,'status','new','createdAt',(extract(epoch from now())*1000)::bigint,
    'updatedAt',(extract(epoch from now())*1000)::bigint,'form',f,'quote',q,'rooms',public.bait_rooms_of(public.bait_alloc(f,c,null)->'ids',c),'cfgVersion',c->'version');
  insert into public.bait_bookings(id,ref,status,date_from,date_to,phone,data) values (vid,vref,'new',(f->>'from')::date,(f->>'to')::date,ph,r);
  insert into public.bait_log(booking_id,action,to_status,actor) values (vid,'submit','new',auth.uid());
  return jsonb_build_object('ok',true,'booking',r);
end $$;

-- التوفر: فترات الحجوزات المعتمدة فقط بدون بيانات شخصية
create or replace function public.bait_availability() returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'from',date_from,'to',date_to,
    'rooms',coalesce(data->'rooms'->'ids','[]'::jsonb),'whole',(data->'form'->>'mode')='whole')),'[]'::jsonb)
  from public.bait_bookings where status in ('approved','confirmed','checkedin') and date_to >= public.bait_today()-60;
$$;

-- متابعة الطلب: رقم الطلب + الجوال معاً (بدون الملاحظات الداخلية)
create or replace function public.bait_track(p_ref text, p_phone text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg((data - 'log' - 'internalNote') || jsonb_build_object('id',id,'status',status)),'[]'::jsonb)
  from public.bait_bookings
  where ref=upper(trim(p_ref)) and phone=regexp_replace(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'),'^966','0');
$$;

-- إلغاء صاحب الطلب لطلبه (قبل التأكيد فقط)
create or replace function public.bait_cancel(p_ref text, p_phone text) returns boolean
language plpgsql security definer set search_path=public as $$
declare b record;
begin
  select * into b from public.bait_bookings where ref=upper(trim(p_ref))
    and phone=regexp_replace(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'),'^966','0') and status in ('new','approved') for update;
  if not found then return false; end if;
  update public.bait_bookings set status='cancelled', updated_at=now(),
    data = data || jsonb_build_object('status','cancelled','cancelledBy','requester','updatedAt',(extract(epoch from now())*1000)::bigint)
    where id=b.id;
  insert into public.bait_log(booking_id,action,from_status,to_status,actor) values (b.id,'cancel_by_requester',b.status,'cancelled',auth.uid());
  return true;
end $$;

-- الإدارة: تغيير حالة الطلب (بمسار محدد + فحص السعة + سجل)
create or replace function public.bait_set_status(p_id text, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare b record; allowed text[]; al jsonb; newrooms jsonb; c jsonb := public.bait_cfg(); note text := nullif(trim(coalesce(p_note,'')),'');
begin
  if public.bait_role() is null then return jsonb_build_object('ok',false,'error','لا توجد صلاحية.'); end if;
  perform pg_advisory_xact_lock(hashtext('bait_capacity'));
  select * into b from public.bait_bookings where id=p_id for update;
  if not found then return jsonb_build_object('ok',false,'error','الطلب غير موجود.'); end if;
  allowed := case b.status when 'new' then array['approved','rejected']
    when 'approved' then array['confirmed','rejected','cancelled'] when 'confirmed' then array['checkedin','cancelled']
    when 'checkedin' then array['done'] else array[]::text[] end;
  if not (p_status = any(allowed)) then return jsonb_build_object('ok',false,'error','لا يمكن نقل الطلب من حالته الحالية إلى هذه الحالة.'); end if;
  if p_status='rejected' and note is null then return jsonb_build_object('ok',false,'error','اكتب سبب الاعتذار.'); end if;
  if p_status in ('approved','confirmed') then
    al := public.bait_alloc(b.data->'form',c,b.id);
    if not (al->>'ok')::boolean then return jsonb_build_object('ok',false,'error','لا توجد غرف متاحة لهذا الطلب في تواريخه. راجع الحجوزات المعتمدة.'); end if;
    newrooms := public.bait_rooms_of(al->'ids',c);
  end if;
  update public.bait_bookings set status=p_status, updated_at=now(),
    data = data || jsonb_build_object('status',p_status,'adminNote',note,'updatedAt',(extract(epoch from now())*1000)::bigint,
      'at_'||p_status,(extract(epoch from now())*1000)::bigint) || case when newrooms is not null then jsonb_build_object('rooms',newrooms) else '{}'::jsonb end
    where id=b.id;
  insert into public.bait_log(booking_id,action,from_status,to_status,note,actor) values (b.id,'status',b.status,p_status,note,auth.uid());
  return jsonb_build_object('ok',true);
end $$;

-- الإدارة: ملاحظة للمستأجر بدون تغيير الحالة
create or replace function public.bait_set_note(p_id text, p_note text) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
  if public.bait_role() is null then return jsonb_build_object('ok',false,'error','لا توجد صلاحية.'); end if;
  update public.bait_bookings set updated_at=now(), data = data || jsonb_build_object('adminNote',nullif(trim(coalesce(p_note,'')),'')) where id=p_id;
  insert into public.bait_log(booking_id,action,note,actor) values (p_id,'note',p_note,auth.uid());
  return jsonb_build_object('ok',found);
end $$;

-- الإدارة: حفظ الأسعار والإعدادات (مع تحقق)
create or replace function public.bait_save_config(p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare old jsonb := public.bait_cfg(); k text; c jsonb;
begin
  if coalesce(public.bait_role(),'') not in ('owner','manager') then return jsonb_build_object('ok',false,'error','تعديل الأسعار للمالك والمدير فقط.'); end if;
  for k in select jsonb_object_keys(p_cfg->'prices') loop
    if coalesce((p_cfg->'prices'->k->>'wd')::numeric,-1)<0 or coalesce((p_cfg->'prices'->k->>'we')::numeric,-1)<0 then
      return jsonb_build_object('ok',false,'error','سعر غير صحيح: '||k); end if; end loop;
  if (p_cfg->>'vat')::numeric not between 0 and 100 or (p_cfg->>'maxDisc')::numeric not between 0 and 100
     or (p_cfg->'orgDisc'->>'staff')::numeric not between 0 and 100 or (p_cfg->>'depositPct')::numeric not between 0 and 100 then
    return jsonb_build_object('ok',false,'error','نسبة خارج المدى 0–100.'); end if;
  -- أقسام الحجز: اسم، مفتاح، غرف موجودة، وأسعار صحيحة
  if jsonb_typeof(p_cfg->'packages') is distinct from 'array' then return jsonb_build_object('ok',false,'error','قائمة الأقسام غير صحيحة.'); end if;
  if exists(select 1 from jsonb_array_elements(p_cfg->'packages') p where coalesce(trim(p->>'label'),'')='' or coalesce(p->>'key','') !~ '^[a-z0-9_]{1,24}$'
     or p->>'key' in ('whole','rooms','beds') or jsonb_typeof(p->'rooms')<>'array' or jsonb_array_length(p->'rooms')=0
     or coalesce((p->'price'->>'wd')::numeric,-1)<0 or coalesce((p->'price'->>'we')::numeric,-1)<0
     or exists(select 1 from jsonb_array_elements_text(p->'rooms') x where not exists(select 1 from jsonb_array_elements(old->'capacity'->'rooms') r where r->>'n'=x))) then
    return jsonb_build_object('ok',false,'error','راجع أقسام الحجز: الاسم والغرف والأسعار.'); end if;
  if (select count(*) from jsonb_array_elements(p_cfg->'packages')) <> (select count(distinct p->>'key') from jsonb_array_elements(p_cfg->'packages') p) then
    return jsonb_build_object('ok',false,'error','يوجد قسمان بنفس المفتاح.'); end if;
  -- السعة لا تتغير من الواجهة
  c := p_cfg || jsonb_build_object('capacity',old->'capacity','version',coalesce((old->>'version')::int,1)+1);
  insert into public.bait_config(id,data,updated_at,updated_by) values ('main',c,now(),auth.uid())
    on conflict (id) do update set data=excluded.data, updated_at=now(), updated_by=auth.uid();
  insert into public.bait_log(action,note,actor) values ('config','version '||(c->>'version'),auth.uid());
  return jsonb_build_object('ok',true,'config',c);
end $$;


-- ---------- 3ب) فريق الإدارة والدعوات ----------
create or replace function public.bait_me() returns jsonb
language sql stable security definer set search_path=public as $$
  select jsonb_build_object('role',public.bait_role(),'name',(select name from public.bait_team where user_id=auth.uid()));
$$;

create or replace function public.bait_team_list() returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
  if public.bait_role() is distinct from 'owner' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'phone',phone,'role',role,'status',
      case when status='invited' and expires_at<now() then 'expired' else status end,
      'invited_at',invited_at,'joined_at',joined_at) order by status, name) from public.bait_team),'[]'::jsonb);
end $$;

-- إنشاء دعوة أو تجديدها: يعيد رمزاً يُرسل في رابط الدعوة (صالح 7 أيام)
create or replace function public.bait_team_invite(p_name text, p_phone text, p_role text) returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare ph text := regexp_replace(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'),'^966','0'); tok text; t record;
begin
  if public.bait_role() is distinct from 'owner' then return jsonb_build_object('ok',false,'error','الدعوات من مدير المنصة فقط.'); end if;
  if coalesce(trim(p_name),'')='' then return jsonb_build_object('ok',false,'error','اكتب الاسم.'); end if;
  if ph !~ '^05[0-9]{8}$' then return jsonb_build_object('ok',false,'error','اكتب رقم جوال سعودي صحيح يبدأ بـ 05.'); end if;
  if p_role not in ('manager','staff') then return jsonb_build_object('ok',false,'error','الدور غير صحيح.'); end if;
  select * into t from public.bait_team where phone=ph;
  if found and t.status='active' then return jsonb_build_object('ok',false,'error','هذا الرقم عضو مفعّل في فريق الإدارة.'); end if;
  tok := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into public.bait_team(name,phone,role,status,token_hash,expires_at,invited_by,user_id)
    values (trim(p_name),ph,p_role,'invited',encode(sha256(convert_to(tok,'UTF8')),'hex'),now()+interval '7 days',auth.uid(),null)
    on conflict (phone) do update set name=excluded.name, role=excluded.role, status='invited', token_hash=excluded.token_hash,
      expires_at=excluded.expires_at, invited_at=now(), invited_by=excluded.invited_by, user_id=null, joined_at=null;
  insert into public.bait_log(action,note,actor) values ('team_invite',trim(p_name)||' '||ph||' '||p_role,auth.uid());
  return jsonb_build_object('ok',true,'token',tok);
end $$;

-- تفعيل أو إيقاف عضو أو تغيير دوره أو حذف دعوة
create or replace function public.bait_team_set(p_id bigint, p_action text, p_role text default null) returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare t record;
begin
  if public.bait_role() is distinct from 'owner' then return jsonb_build_object('ok',false,'error','لمدير المنصة فقط.'); end if;
  select * into t from public.bait_team where id=p_id for update;
  if not found then return jsonb_build_object('ok',false,'error','العضو غير موجود.'); end if;
  if p_action='disable' then update public.bait_team set status='disabled', token_hash=null where id=p_id;
  elsif p_action='enable' then
    if t.user_id is null then return jsonb_build_object('ok',false,'error','لم يقبل الدعوة بعد. أرسل له دعوة جديدة.'); end if;
    update public.bait_team set status='active' where id=p_id;
  elsif p_action='role' and p_role in ('manager','staff') then update public.bait_team set role=p_role where id=p_id;
  elsif p_action='delete' then delete from public.bait_team where id=p_id;
  else return jsonb_build_object('ok',false,'error','إجراء غير معروف.'); end if;
  insert into public.bait_log(action,note,actor) values ('team_'||p_action,t.name||' '||t.phone,auth.uid());
  return jsonb_build_object('ok',true);
end $$;

-- صفحة الدعوة: بيانات الدعوة قبل الدخول (الاسم والدور فقط)
create or replace function public.bait_invite_info(p_token text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce((select jsonb_build_object('ok',true,'name',name,'role',role,'phone',phone) from public.bait_team
    where token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex') and status='invited' and expires_at>now()),
    jsonb_build_object('ok',false));
$$;

-- قبول الدعوة: يلزم أن يكون الحساب المسجّل هو نفس جوال الدعوة
create or replace function public.bait_accept_invite(p_token text) returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare t record; em text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','سجّل الدخول أولاً.'); end if;
  select * into t from public.bait_team where token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex') and status='invited' and expires_at>now() for update;
  if not found then return jsonb_build_object('ok',false,'error','الدعوة غير صالحة أو انتهت. اطلب دعوة جديدة.'); end if;
  if em <> '966'||substr(t.phone,2)||'@phone.almanar.app' then return jsonb_build_object('ok',false,'error','ادخل برقم الجوال نفسه الذي وصلته الدعوة.'); end if;
  update public.bait_team set user_id=auth.uid(), status='active', token_hash=null, joined_at=now() where id=t.id;
  insert into public.bait_log(action,note,actor) values ('team_join',t.name||' '||t.phone,auth.uid());
  return jsonb_build_object('ok',true,'role',t.role,'name',t.name);
end $$;

revoke all on function public.bait_me(), public.bait_team_list(), public.bait_team_invite(text,text,text), public.bait_team_set(bigint,text,text),
  public.bait_invite_info(text), public.bait_accept_invite(text) from public;
grant execute on function public.bait_me(), public.bait_team_list(), public.bait_team_invite(text,text,text), public.bait_team_set(bigint,text,text),
  public.bait_accept_invite(text) to authenticated;
grant execute on function public.bait_invite_info(text) to anon, authenticated;

-- ---------- 4) الصلاحيات على الدوال ----------
revoke all on function public.bait_cfg(), public.bait_pkg(jsonb,text), public.bait_alloc(jsonb,jsonb,text), public.bait_rooms_of(jsonb,jsonb), public.bait_quote(jsonb,jsonb,date),
  public.bait_validate(jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.bait_price(jsonb), public.bait_submit(jsonb), public.bait_availability(), public.bait_track(text,text),
  public.bait_cancel(text,text), public.bait_set_status(text,text,text), public.bait_set_note(text,text), public.bait_save_config(jsonb) from public;
grant execute on function public.bait_price(jsonb), public.bait_submit(jsonb), public.bait_availability(),
  public.bait_track(text,text), public.bait_cancel(text,text) to anon, authenticated;
grant execute on function public.bait_set_status(text,text,text), public.bait_set_note(text,text), public.bait_save_config(jsonb) to authenticated;

-- ---------- 5) الإعدادات الأولية ----------
insert into public.bait_config(id,data) values ('main', $cfg$ {"version": 3, "demo": false, "capacity": {"rooms": [{"n": 1, "t": "st", "beds": 10}, {"n": 2, "t": "st", "beds": 10}, {"n": 3, "t": "st", "beds": 12}, {"n": 4, "t": "st", "beds": 8}, {"n": 5, "t": "sup", "beds": 3}, {"n": 6, "t": "st", "beds": 10}, {"n": 7, "t": "st", "beds": 10}, {"n": 8, "t": "sup", "beds": 1}, {"n": 9, "t": "sup", "beds": 4}]}, "packages": [{"key": "main", "label": "القسم الرئيسي", "rooms": [1, 2, 3, 4, 5, 6, 9], "areas": "الصالة الرئيسية ومنطقة الألعاب والمصلى", "price": {"wd": 2400, "we": 3000}, "active": true}, {"key": "suite", "label": "الجناح المستقل", "rooms": [7, 8], "areas": "الصالة الصغيرة", "price": {"wd": 450, "we": 560}, "active": true}], "presets": [{"key": "trip", "t": "الرحلة المدرسية", "who": "للمدارس · ليلتان", "nights": 2, "mode": "main", "inc": ["القسم الرئيسي بغرفه وصالاته والمصلى", "4 ساعات ملاعب وساعتان مسبح", "مشواران بالباص", "إعاشة كاملة: 3 وجبات يومياً"], "addons": {"field": 4, "pool": 2, "bus": 2}, "meals": true, "hosp": false, "classPerDay": 0, "gold": false, "active": true}, {"key": "camp", "t": "المعسكر الصيفي", "who": "للمعسكرات والأندية · أسبوع", "nights": 7, "mode": "whole", "inc": ["المبنى كاملاً بخصم على المرافق والخدمات", "10 ساعات ملاعب و6 مسبح و6 صالة رياضية", "إعاشة كاملة وركن ضيافة يومي", "نظافة إضافية يومين"], "addons": {"field": 10, "pool": 6, "gym": 6, "clean": 2}, "meals": true, "hosp": true, "classPerDay": 0, "gold": true, "active": true}, {"key": "program", "t": "البرنامج الإثرائي", "who": "للبرامج التعليمية والدورات · 3 ليالٍ", "nights": 3, "mode": "beds", "inc": ["المبيت حسب العدد", "فصلان دراسيان يومياً ومصادر التعلم", "المجلس الرئيسي بشاشة العرض للافتتاح والختام", "إعاشة كاملة وركن ضيافة"], "addons": {"lrc": 6, "majlis": 4}, "meals": true, "hosp": true, "classPerDay": 2, "gold": false, "active": true}], "checkIn": "14:00", "checkOut": "12:00", "minNights": 1, "maxNights": 60, "ratio": 15, "weekendNights": [4, 5], "prices": {"whole": {"wd": 2800, "we": 3500}, "roomStBed": {"wd": 35, "we": 45}, "roomSupBed": {"wd": 60, "we": 75}, "bedSt": {"wd": 45, "we": 55}, "bedSup": {"wd": 80, "we": 100}}, "addons": [{"key": "field", "label": "الملاعب", "unit": "ساعة", "price": 150, "group": "المرافق"}, {"key": "pool", "label": "المسبح", "unit": "ساعة", "price": 250, "group": "المرافق"}, {"key": "gym", "label": "الصالة الرياضية", "unit": "ساعة", "price": 150, "group": "المرافق"}, {"key": "lrc", "label": "مصادر التعلم", "unit": "ساعة", "price": 100, "group": "المرافق"}, {"key": "meet", "label": "غرفة اجتماعات", "unit": "ساعة", "price": 100, "group": "المرافق"}, {"key": "class", "label": "فصل دراسي", "unit": "يوم", "price": 300, "group": "المرافق"}, {"key": "majlis", "label": "المجلس الرئيسي مع شاشة عرض (للورش واللقاءات)", "unit": "ساعة", "price": 200, "group": "المرافق"}, {"key": "bus", "label": "نقل بالباص", "unit": "مشوار", "price": 400, "group": "الخدمات"}, {"key": "pickup", "label": "نقل بالوانيت", "unit": "مشوار", "price": 150, "group": "الخدمات"}, {"key": "clean", "label": "نظافة إضافية", "unit": "يوم", "price": 200, "group": "الخدمات"}, {"key": "guard", "label": "حراسة إضافية (مناوبة 8 ساعات)", "unit": "مناوبة", "price": 250, "group": "الخدمات"}, {"key": "meals", "label": "إعاشة (وجبة للشخص)", "unit": "وجبة", "price": 35, "group": "الخدمات"}, {"key": "hosp", "label": "ركن ضيافة مفتوح (قهوة وشاي وماء)", "unit": "يوم", "price": 150, "group": "الخدمات"}], "wholeAddonDisc": 20, "durationTiers": [{"nights": 7, "pct": 10}, {"nights": 14, "pct": 15}, {"nights": 30, "pct": 25}], "orgDisc": {"internal": 0, "staff": 50, "school": 10, "gov": 10, "charity": 15, "company": 0, "other": 0}, "internal": {"insurance": 2000, "facilitiesFree": true, "ops": [{"key": "sec", "label": "رسوم الأمن والحراسة", "price": 150}, {"key": "cln", "label": "رسوم النظافة", "price": 150}, {"key": "utl", "label": "رسوم تشغيلية (كهرباء ومياه وتكييف)", "price": 100}]}, "staffAddons": true, "staffVat": true, "earlyDays": 30, "earlyPct": 5, "promos": {"ANDALUS10": 10}, "maxDisc": 30, "vat": 15, "depositPct": 30, "insurance": 1500, "cancel": {"freeDays": 14, "halfDays": 7}, "contact": {"phone": "0545967881", "name": "م. محمد نور عمر"}}$cfg$::jsonb) on conflict (id) do nothing;
select 'ok' as result;
