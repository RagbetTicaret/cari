// =====================================================================
// RAGBET TİCARET - ORTAK YEDEKLEME YARDIMCI KÜTÜPHANESİ
// Bu dosyayı kullanan sayfalarda: Supabase client "sb" adıyla,
// SheetJS kütüphanesi <script src=".../xlsx..."></script> ile
// önceden yüklenmiş olmalıdır.
// =====================================================================

async function fetchAllDataForBackup(sb){
  const [cari, stok, subeStok, stokHareket, satis, satisKalem, kasaHareket, sube] = await Promise.all([
    sb.from('cari').select('*'),
    sb.from('stok').select('*'),
    sb.from('sube_stok').select('*'),
    sb.from('stok_hareket').select('*'),
    sb.from('satis').select('*'),
    sb.from('satis_kalem').select('*'),
    sb.from('kasa_hareket').select('*'),
    sb.from('sube').select('*'),
  ]);
  return {
    Cari: cari.data || [],
    Stok: stok.data || [],
    SubeStok: subeStok.data || [],
    StokHareket: stokHareket.data || [],
    Satis: satis.data || [],
    SatisKalem: satisKalem.data || [],
    KasaHareket: kasaHareket.data || [],
    Sube: sube.data || [],
  };
}

function buildAndDownloadExcel(dataset, dosyaEtiketi){
  const wb = XLSX.utils.book_new();
  Object.entries(dataset).forEach(([sheetName, rows])=>{
    const ws = XLSX.utils.json_to_sheet(rows.length ? rows : [{ bilgi: 'Bu tabloda henüz veri yok' }]);
    XLSX.utils.book_append_sheet(wb, ws, sheetName.slice(0, 31));
  });
  const dosyaAdi = `RagbetTicaret_Yedek_${dosyaEtiketi}.xlsx`;
  XLSX.writeFile(wb, dosyaAdi);
  return dosyaAdi;
}

async function yedekAl(sb, tip){
  const dataset = await fetchAllDataForBackup(sb);
  const now = new Date();
  const tarihStr = now.toISOString().slice(0, 10);
  const saatStr = now.toTimeString().slice(0, 5).replace(':', '');
  const dosyaAdi = buildAndDownloadExcel(dataset, `${tip}_${tarihStr}_${saatStr}`);

  localStorage.setItem('yedek_son_' + tip, now.toISOString());
  const gecmis = JSON.parse(localStorage.getItem('yedek_gecmisi') || '[]');
  gecmis.unshift({ tip, tarih: now.toISOString(), dosyaAdi });
  localStorage.setItem('yedek_gecmisi', JSON.stringify(gecmis.slice(0, 50)));

  return dosyaAdi;
}

function gunFarki(tarihISO){
  if (!tarihISO) return Infinity;
  return (Date.now() - new Date(tarihISO).getTime()) / (1000 * 60 * 60 * 24);
}

function bekle(ms){ return new Promise(r => setTimeout(r, ms)); }

// Her sayfa açılışında sessizce çağrılır. Süresi gelen yedekler varsa
// otomatik indirir ve (varsa) bildirimFn ile kullanıcıya küçük bir
// bilgi notu gösterir.
async function otomatikYedekKontrol(sb, bildirimFn){
  const kontroller = [
    { tip: 'gunluk',  esikGun: 1,  etiket: 'Günlük' },
    { tip: 'haftalik', esikGun: 7,  etiket: 'Haftalık' },
    { tip: 'aylik',   esikGun: 30, etiket: 'Aylık' },
  ];
  for (const k of kontroller){
    const sonTarih = localStorage.getItem('yedek_son_' + k.tip);
    if (gunFarki(sonTarih) >= k.esikGun){
      try{
        const dosyaAdi = await yedekAl(sb, k.tip);
        if (bildirimFn) bildirimFn(`${k.etiket} yedek indirildi: ${dosyaAdi}`);
      } catch(e){
        console.error('Otomatik yedek hatası:', e);
      }
      await bekle(1200); // aynı anda çoklu indirmenin tarayıcı tarafından engellenmesini azaltır
    }
  }
}
