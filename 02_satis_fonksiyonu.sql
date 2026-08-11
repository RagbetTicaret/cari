-- =====================================================================
-- AŞAMA 5: SATIŞ İŞLEMİ FONKSİYONU
-- =====================================================================
-- KULLANIM: Supabase projenizde "SQL Editor" bölümüne girin, bu
-- dosyanın tamamını yapıştırıp "Run" butonuna basın.
--
-- BU FONKSİYON NE YAPAR:
-- Bir satış yapıldığında; satış başlığı + satış kalemleri + stok
-- düşürme + (peşinse) kasa kaydı hepsi TEK SEFERDE, ya hep ya hiç
-- mantığıyla kaydedilir. Ortasında bir hata olursa hiçbir şey
-- kaydedilmez, yarım kalmış işlem oluşmaz.
-- =====================================================================

create or replace function create_satis(
  p_sube_id uuid,
  p_cari_id uuid,
  p_kullanici_id uuid,
  p_belge_tipi text,
  p_odeme_tipi text,
  p_kalemler jsonb
) returns uuid
language plpgsql
as $$
declare
  v_satis_id uuid;
  v_belge_no text;
  v_ara_toplam numeric(14,2) := 0;
  v_kdv_toplam numeric(14,2) := 0;
  v_genel_toplam numeric(14,2) := 0;
  v_kalem jsonb;
  v_satir_tutar numeric(14,2);
  v_satir_kdv numeric(14,2);
  v_mevcut_miktar numeric(14,2);
  v_yeni_miktar numeric(14,2);
  v_sayac int;
  v_odeme_sekli text;
begin
  -- Belge numarasını otomatik oluştur: YIL-SIRANO (ör. 2026-00001)
  select coalesce(max(cast(split_part(belge_no, '-', 2) as integer)), 0) + 1
    into v_sayac
    from satis
    where belge_no like to_char(now(), 'YYYY') || '-%';
  v_belge_no := to_char(now(), 'YYYY') || '-' || lpad(v_sayac::text, 5, '0');

  -- Toplamları hesapla
  for v_kalem in select * from jsonb_array_elements(p_kalemler)
  loop
    v_satir_tutar := (v_kalem->>'miktar')::numeric * (v_kalem->>'birim_fiyat')::numeric
                     * (1 - coalesce((v_kalem->>'iskonto_yuzde')::numeric, 0) / 100);
    v_satir_kdv := v_satir_tutar * (v_kalem->>'kdv_orani')::numeric / 100;
    v_ara_toplam := v_ara_toplam + v_satir_tutar;
    v_kdv_toplam := v_kdv_toplam + v_satir_kdv;
  end loop;
  v_genel_toplam := v_ara_toplam + v_kdv_toplam;

  -- Satış başlığı
  insert into satis (sube_id, cari_id, kullanici_id, belge_no, belge_tipi, odeme_tipi, ara_toplam, kdv_toplam, genel_toplam)
  values (p_sube_id, p_cari_id, p_kullanici_id, v_belge_no, p_belge_tipi, p_odeme_tipi, v_ara_toplam, v_kdv_toplam, v_genel_toplam)
  returning id into v_satis_id;

  -- Her kalem için: satır ekle, stok düş, hareket logla
  for v_kalem in select * from jsonb_array_elements(p_kalemler)
  loop
    v_satir_tutar := (v_kalem->>'miktar')::numeric * (v_kalem->>'birim_fiyat')::numeric
                     * (1 - coalesce((v_kalem->>'iskonto_yuzde')::numeric, 0) / 100);

    insert into satis_kalem (satis_id, stok_id, miktar, birim_fiyat, kdv_orani, iskonto_yuzde, tutar)
    values (
      v_satis_id,
      (v_kalem->>'stok_id')::uuid,
      (v_kalem->>'miktar')::numeric,
      (v_kalem->>'birim_fiyat')::numeric,
      (v_kalem->>'kdv_orani')::numeric,
      coalesce((v_kalem->>'iskonto_yuzde')::numeric, 0),
      v_satir_tutar
    );

    select miktar into v_mevcut_miktar
      from sube_stok
      where sube_id = p_sube_id and stok_id = (v_kalem->>'stok_id')::uuid;

    v_yeni_miktar := coalesce(v_mevcut_miktar, 0) - (v_kalem->>'miktar')::numeric;

    insert into sube_stok (sube_id, stok_id, miktar)
    values (p_sube_id, (v_kalem->>'stok_id')::uuid, v_yeni_miktar)
    on conflict (sube_id, stok_id) do update set miktar = v_yeni_miktar;

    insert into stok_hareket (sube_id, stok_id, tip, miktar, aciklama, kullanici_id)
    values (p_sube_id, (v_kalem->>'stok_id')::uuid, 'cikis', (v_kalem->>'miktar')::numeric,
            'Satış - ' || v_belge_no, p_kullanici_id);
  end loop;

  -- Ödeme peşinse (cari değilse) kasaya da işlensin
  if p_odeme_tipi <> 'cari' then
    v_odeme_sekli := case when p_odeme_tipi = 'cek_senet' then 'cek' else p_odeme_tipi end;
    insert into kasa_hareket (sube_id, tip, tutar, odeme_sekli, cari_id, aciklama, kullanici_id)
    values (p_sube_id, 'tahsilat', v_genel_toplam, v_odeme_sekli, p_cari_id,
            'Satış geliri - ' || v_belge_no, p_kullanici_id);
  end if;

  return v_satis_id;
end;
$$;

grant execute on function create_satis to authenticated;

-- =====================================================================
-- BİTTİ. "Success. No rows returned" mesajı görürseniz fonksiyon
-- hazır demektir.
-- =====================================================================
