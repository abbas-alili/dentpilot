-- =============================================================================
-- Development seed — loaded by `supabase db reset` (local only).
-- PLACEHOLDER VALUES: dentist names, services, durations, approval flags and
-- working hours and prices are examples
-- until Avenue Dent confirms them. See SOP.md, "Open questions".
-- Fixed uuids make test data easy to recognise:  …0a = clinic, …d1 = dentist,
-- …e1 = service, …f1 = patient.
-- =============================================================================

-- Settings from Dr. Ayten's answers (2026-11-02): shadow mode (default), every booking
-- approved by the doctor, a specific doctor per patient, booking up to a month ahead.
insert into core.clinics (id, name, timezone, all_bookings_need_approval, offer_any_dentist, booking_horizon_days) values
  ('00000000-0000-0000-0000-00000000000a', 'Avenue Dent (dev)', 'Asia/Baku', true, false, 30);

insert into core.professionals (id, clinic_id, display_name, sort_order) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000000a', 'Dr. Elvin',  1),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000000a', 'Dr. Nərmin', 2);

insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes, buffer_minutes, requires_approval, sort_order) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', 'svc_exam',  'Müayinə',    'Осмотр',  30, 0,  false, 1),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-00000000000a', 'svc_clean', 'Təmizləmə',  'Чистка',  45, 15, false, 2),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-00000000000a', 'svc_fill',  'Plomb',      'Пломба',  60, 15, true,  3);

-- Working hours (placeholder): both dentists Mon–Sat 10:00–19:00.
insert into core.schedules (clinic_id, professional_id, weekday, start_time, end_time, valid_from)
select '00000000-0000-0000-0000-00000000000a', p.id, d, '10:00', '19:00', date '2026-01-01'
  from core.professionals p, generate_series(1, 6) as d
 where p.clinic_id = '00000000-0000-0000-0000-00000000000a';

insert into core.patients (id, clinic_id, wa_id, display_name, preferred_language) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', '994500000001', 'Test Pasiyent', 'az'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', '994500000002', 'Тест Пациент',  'ru');

-- Internal price list (placeholder prices, AZN).
insert into clinical.price_list (clinic_id, code, name, price_azn) values
  ('00000000-0000-0000-0000-00000000000a', 'exam',              'Müayinə',             20.00),
  ('00000000-0000-0000-0000-00000000000a', 'cleaning',          'Peşəkar təmizləmə',   60.00),
  ('00000000-0000-0000-0000-00000000000a', 'filling_composite', 'Kompozit plomb',      80.00),
  ('00000000-0000-0000-0000-00000000000a', 'xray_periapical',   'Rentgen (prisel)',    10.00);

-- FAQ examples (UNAPPROVED — staff review and approve them in the web app).
insert into core.kb_entries (clinic_id, language, topic, question, answer, sort_order) values
  ('00000000-0000-0000-0000-00000000000a', 'az', 'hours',    'İş saatlarınız neçədir?', 'Bazar ertəsi – Şənbə, 10:00–19:00.', 1),
  ('00000000-0000-0000-0000-00000000000a', 'ru', 'hours',    'Какие у вас часы работы?', 'Пн–Сб, 10:00–19:00.',             1),
  ('00000000-0000-0000-0000-00000000000a', 'az', 'location', 'Ünvanınız haradadır?',    '<ünvan — klinika təsdiqləməlidir>', 2);
