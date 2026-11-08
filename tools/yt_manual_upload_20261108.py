#!/usr/bin/env python3
"""One-off owner-authorized FinTimes upload. No OAuth token is printed or persisted."""
import os,sys,json,time,hashlib,datetime,pathlib,zipfile,urllib.request
from zoneinfo import ZoneInfo

CHANNEL="UC9uSaourNW4ZAnlO4bRN_Cg"
STORY_ID="fintimes-market-rally-20261108"
VIDEO_SHA256="59055ca5ae71cb46bbdb2d4701dc414c210ae7372c1807bab21049a3682e9242"
ZIP_SHA256="ac6ea9c628a68f3ce4ef71859dd780f5062ddc06973a89847b5b99977f38f933"
ZIP_URL="https://d2ol7oe51mr4n9.cloudfront.net/user_3J88GcXnX5h6lAm7IknZFGAlMqo/222ee2fb-8f97-4c0e-b8c2-ed081b07ac0d.zip"
ROOT=pathlib.Path(__file__).resolve().parent
DATA=json.loads((ROOT/"fintimes_20261108_yt_metadata.json").read_text())
OUT=ROOT/"upload_receipt.json"
VIDEO_NAME="FIN_TIMES_2026-11-08_India_Stocks_Explained_WITH_JINGLE.mp4"
THUMB_NAME="FIN_TIMES_2026-11-08_THUMBNAIL.jpg"
SRT_NAME="FinTimes_2026-11-08_captions.srt"

def receipt(data):
    OUT.write_text(json.dumps(data,indent=2,ensure_ascii=False))
    print("RECEIPT",json.dumps(data,ensure_ascii=False),flush=True)

def get_youtube():
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build
    creds=Credentials(token=None,refresh_token=os.environ["YOUTUBE_REFRESH_TOKEN"],
       token_uri="https://oauth2.googleapis.com/token",client_id=os.environ["YOUTUBE_CLIENT_ID"],
       client_secret=os.environ["YOUTUBE_CLIENT_SECRET"],
       scopes=["https://www.googleapis.com/auth/youtube.force-ssl"])
    return build("youtube","v3",credentials=creds,cache_discovery=False)

def exact_channel(yt):
    channels=yt.channels().list(part="id,contentDetails,snippet",mine=True).execute().get("items",[])
    ids=[x["id"] for x in channels]
    if ids!=[CHANNEL]:
        raise RuntimeError("OAuth channel mismatch: refusing upload")
    return channels[0]["contentDetails"]["relatedPlaylists"]["uploads"],channels[0]["snippet"]["title"]

def recent_videos(yt,playlist):
    page=yt.playlistItems().list(part="snippet",playlistId=playlist,maxResults=50).execute()
    ids=[x["snippet"]["resourceId"]["videoId"] for x in page.get("items",[]) if x.get("snippet",{}).get("resourceId",{}).get("videoId")]
    if not ids:return []
    result=[]
    for off in range(0,len(ids),50):
        result+=yt.videos().list(part="snippet,status,processingDetails",id=",".join(ids[off:off+50])).execute().get("items",[])
    return result

def today_published(items):
    today=datetime.datetime.now(ZoneInfo("Asia/Kolkata")).date()
    accepted=[]
    for x in items:
        if x.get("status",{}).get("privacyStatus")!="public":continue
        ts=x.get("snippet",{}).get("publishedAt")
        if not ts:continue
        moment=datetime.datetime.fromisoformat(ts.replace("Z","+00:00")).astimezone(ZoneInfo("Asia/Kolkata"))
        if moment.date()==today:accepted.append(x["id"])
    return accepted

def duplicates(items):
    for x in items:
        sn=x.get("snippet",{})
        if ("FinTimes story ID: "+STORY_ID) in sn.get("description","") or sn.get("title","").casefold()==DATA["title"].casefold():
            return x
    return None

def check_bytes(path,checksum):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for block in iter(lambda:f.read(2**20),b""):h.update(block)
    if h.hexdigest()!=checksum:raise RuntimeError("Media checksum mismatch: "+path.name)

def download_media():
    package=ROOT/"video_bundle.zip"
    if not package.exists():
        urllib.request.urlretrieve(ZIP_URL,str(package))
    check_bytes(package,ZIP_SHA256)
    with zipfile.ZipFile(package) as z:
        names=z.namelist()
        for n in (VIDEO_NAME,THUMB_NAME,SRT_NAME):
            if n not in names:raise RuntimeError("Package missing "+n)
            z.extract(n,ROOT)
    check_bytes(ROOT/VIDEO_NAME,VIDEO_SHA256)
    return ROOT/VIDEO_NAME,ROOT/THUMB_NAME,ROOT/SRT_NAME

def get_item(yt,vid):
    x=yt.videos().list(part="snippet,status,processingDetails",id=vid).execute().get("items",[])
    if len(x)!=1 or x[0]["snippet"]["channelId"]!=CHANNEL:
        raise RuntimeError("Uploaded video wrong channel")
    return x[0]

def update_status(yt,item,kind,publish_at=None):
    st=item["status"]
    allowed={"embeddable","license","publicStatsViewable","selfDeclaredMadeForKids","containsSyntheticMedia"}
    new={k:v for k,v in st.items() if k in allowed}
    new["privacyStatus"]=kind
    if publish_at:new["publishAt"]=publish_at
    return yt.videos().update(part="status",body={"id":item["id"],"status":new}).execute()

def extras(yt,vid,thumb,srt):
    from googleapiclient.http import MediaFileUpload
    report={}
    try:
        yt.thumbnails().set(videoId=vid,media_body=MediaFileUpload(str(thumb),mimetype="image/jpeg")).execute()
        report["thumbnail"]="set"
    except Exception as ex:
        report["thumbnail"]="failed:"+type(ex).__name__
    try:
        yt.captions().insert(part="snippet",body={"snippet":{"videoId":vid,"language":"en","name":"English","isDraft":False}},
          media_body=MediaFileUpload(str(srt),mimetype="application/octet-stream")).execute()
        report["captions"]="uploaded"
    except Exception as ex:
        report["captions"]="failed:"+type(ex).__name__
    return report

def main():
    if len(sys.argv)!=2 or sys.argv[1] not in ("preflight","upload"):
        raise SystemExit("Usage: uploader preflight|upload")
    mode=sys.argv[1]
    required=["YOUTUBE_CLIENT_ID","YOUTUBE_CLIENT_SECRET","YOUTUBE_REFRESH_TOKEN"]
    if any(not os.environ.get(k) for k in required):raise RuntimeError("YouTube credentials absent")
    yt=get_youtube()
    playlist,name=exact_channel(yt)
    if "fin" not in name.lower():raise RuntimeError("Unexpected FinTimes channel display name")
    items=recent_videos(yt,playlist)
    existing=duplicates(items)
    public=today_published(items)
    pre={"mode":mode,"channel":name,"channel_id":CHANNEL,"public_uploads_today":len(public),
         "public_today_video_ids":public,"already_uploaded_video_id":existing["id"] if existing else None,
         "total_recent_videos":len(items)}
    print("PREFLIGHT",json.dumps(pre),flush=True)
    if mode=="preflight":
        receipt({"status":"preflight_only",**pre})
        return
    if existing:
        receipt({"status":"duplicate_blocked","watchUrl":"https://www.youtube.com/watch?v="+existing["id"],
                 "privacy":existing.get("status",{}).get("privacyStatus"),**pre})
        return
    video,thumb,srt=download_media()
    from googleapiclient.http import MediaFileUpload
    desc=DATA["description"]+"\nFinTimes story ID: "+STORY_ID+"\n"
    payload={"snippet":{"title":DATA["title"],"description":desc,"tags":DATA["tags"],"categoryId":"27",
                        "defaultLanguage":"en","defaultAudioLanguage":"en"},
             "status":{"privacyStatus":"private","selfDeclaredMadeForKids":False,"containsSyntheticMedia":True}}
    print("UPLOAD_START",json.dumps({"title":DATA["title"],"video_bytes":video.stat().st_size,"privacy":"private"}),flush=True)
    request=yt.videos().insert(part="snippet,status",body=payload,notifySubscribers=True,
            media_body=MediaFileUpload(str(video),mimetype="video/mp4",resumable=True,chunksize=8*1024*1024))
    res=None
    while res is None:
        _,res=request.next_chunk()
    vid=res.get("id")
    if not vid:raise RuntimeError("Upload response had no video ID")
    receipt({"status":"uploaded_private_unverified","video_id":vid,"watchUrl":"https://www.youtube.com/watch?v="+vid,
            "channel_id":CHANNEL,"media_sha256":VIDEO_SHA256})
    item=get_item(yt,vid)
    if item["status"]["privacyStatus"]!="private":raise RuntimeError("Upload did not remain private")
    extra=extras(yt,vid,thumb,srt)
    processing=item.get("processingDetails",{}).get("processingStatus","unknown")
    for _ in range(42):
        if processing=="succeeded":break
        if processing in ("failed","terminated"):raise RuntimeError("Video processing failed")
        time.sleep(10)
        item=get_item(yt,vid)
        processing=item.get("processingDetails",{}).get("processingStatus","unknown")
    if processing!="succeeded":
        receipt({"status":"private_processing_pending","video_id":vid,"processing":processing,**extra})
        return
    # Preserve owner-approved one public episode per calendar day in IST.
    public=today_published(recent_videos(yt,playlist))
    # If another episode was already released today, schedule after 18:00 IST tomorrow.
    if public:
        now=datetime.datetime.now(ZoneInfo("Asia/Kolkata"))
        next_date=now.date()+datetime.timedelta(days=1)
        target=datetime.datetime.combine(next_date,datetime.time(hour=18),tzinfo=ZoneInfo("Asia/Kolkata"))
        ts=target.astimezone(datetime.timezone.utc).isoformat().replace("+00:00","Z")
        update_status(yt,item,"private",publish_at=ts)
        final=get_item(yt,vid)
        receipt({"status":"scheduled","video_id":vid,"watchUrl":"https://www.youtube.com/watch?v="+vid,
                 "actual_privacy":final["status"]["privacyStatus"],
                 "publishAt":final["status"].get("publishAt",ts),"processing":"succeeded","channel_id":CHANNEL,**extra})
    else:
        update_status(yt,item,"public")
        final=get_item(yt,vid)
        if final["status"]["privacyStatus"]!="public":raise RuntimeError("Public status was not verified")
        receipt({"status":"published_public","video_id":vid,"watchUrl":"https://www.youtube.com/watch?v="+vid,
                 "actual_privacy":"public","processing":"succeeded","channel_id":CHANNEL,**extra})

if __name__=="__main__":
    try:main()
    except Exception as exc:
        receipt({"status":"error_needs_reconciliation","error_type":type(exc).__name__,
                 "error":str(exc)[:550]})
        raise
