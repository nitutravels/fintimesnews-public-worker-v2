#!/usr/bin/env python3
import os,json,hashlib,urllib.request,zipfile,pathlib
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload
from googleapiclient.errors import HttpError
CHANNEL="UC9uSaourNW4ZAnlO4bRN_Cg"
VIDEO_ID="MpmcaUg3gRQ"
ZIP_URL="https://d2ol7oe51mr4n9.cloudfront.net/user_3J88GcXnX5h6lAm7IknZFGAlMqo/222ee2fb-8f97-4c0e-b8c2-ed081b07ac0d.zip"
ZIP_SHA="ac6ea9c628a68f3ce4ef71859dd780f5062ddc06973a89847b5b99977f38f933"
P=pathlib.Path(__file__).resolve().parent
creds=Credentials(token=None,refresh_token=os.environ["YOUTUBE_REFRESH_TOKEN"],token_uri="https://oauth2.googleapis.com/token",client_id=os.environ["YOUTUBE_CLIENT_ID"],client_secret=os.environ["YOUTUBE_CLIENT_SECRET"],scopes=["https://www.googleapis.com/auth/youtube.force-ssl"])
yt=build("youtube","v3",credentials=creds,cache_discovery=False)
channels=yt.channels().list(part="id",mine=True).execute().get("items",[])
if [c["id"] for c in channels]!=[CHANNEL]:raise RuntimeError("Not FinTimes channel")
x=yt.videos().list(part="snippet,status,processingDetails",id=VIDEO_ID).execute().get("items",[])
if len(x)!=1 or x[0]["snippet"]["channelId"]!=CHANNEL:raise RuntimeError("Wrong channel")
v=x[0]
info={"id":VIDEO_ID,"title":v["snippet"]["title"],"privacy":v["status"]["privacyStatus"],
 "publishAt":v["status"].get("publishAt"),"processing":v.get("processingDetails",{}).get("processingStatus"),
 "tags_count":len(v["snippet"].get("tags",[])),"description_length":len(v["snippet"].get("description","")),
 "thumbnail_sizes":list(v["snippet"].get("thumbnails",{}).keys())}
print("POSTFLIGHT_BEFORE",json.dumps(info),flush=True)
try:
 cs=yt.captions().list(part="snippet",videoId=VIDEO_ID).execute().get("items",[])
 print("CAPTIONS",json.dumps([{"lang":c.get("snippet",{}).get("language"),"status":c.get("snippet",{}).get("status")} for c in cs]),flush=True)
except HttpError as e:print("CAPTIONS_CHECK_FAILED",e.resp.status,flush=True)
data=P/"fintimes_thumb_bundle.zip"
urllib.request.urlretrieve(ZIP_URL,str(data))
if hashlib.sha256(data.read_bytes()).hexdigest()!=ZIP_SHA:raise RuntimeError("Unsafe thumbnail package SHA")
with zipfile.ZipFile(data) as zip:
 f=P/"FIN_TIMES_2026-11-08_THUMBNAIL.jpg"
 with f.open("wb") as fp:fp.write(zip.read(f.name))
print("THUMB_FILE",str(f),f.stat().st_size,flush=True)
try:
 output=yt.thumbnails().set(videoId=VIDEO_ID,media_body=MediaFileUpload(str(f),mimetype="image/jpeg")).execute()
 print("THUMBNAIL_SET_SUCCESS",list(output.keys()),flush=True)
except HttpError as e:
 msg=e.content.decode("utf-8","replace")[:1500] if e.content else ""
 try:
  j=json.loads(msg)
  public={"status":e.resp.status,"message":j.get("error",{}).get("message",""),
          "errors":[{"reason":x.get("reason"),"message":x.get("message","")} for x in j.get("error",{}).get("errors",[])]}
 except:public={"status":e.resp.status,"error":msg[:200]}
 print("THUMBNAIL_SET_FAILED",json.dumps(public),flush=True)
(P/"postflight_receipt.json").write_text(json.dumps(info,indent=2))
