#!/usr/bin/env python3
"""One-time owner-requested immediate release of the existing FinTimes upload."""
import json, os, pathlib, time
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

CHANNEL = "UC9uSaourNW4ZAnlO4bRN_Cg"
VIDEO = "MpmcaUg3gRQ"
OUT = pathlib.Path(__file__).resolve().parent / "immediate_release_receipt.json"

def record(payload):
    OUT.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    print("FINTIMES_RELEASE_RECEIPT",json.dumps(payload,ensure_ascii=False),flush=True)

def main():
    c=Credentials(token=None,refresh_token=os.environ["YOUTUBE_REFRESH_TOKEN"],
        token_uri="https://oauth2.googleapis.com/token",
        client_id=os.environ["YOUTUBE_CLIENT_ID"],
        client_secret=os.environ["YOUTUBE_CLIENT_SECRET"],
        scopes=["https://www.googleapis.com/auth/youtube.force-ssl"])
    yt=build("youtube","v3",credentials=c,cache_discovery=False)
    channels=yt.channels().list(part="id,snippet",mine=True).execute().get("items",[])
    if len(channels)!=1 or channels[0]["id"]!=CHANNEL:
        raise RuntimeError("Authenticated channel does not equal FinTimes: no changes made")
    def read():
        videos=yt.videos().list(part="snippet,status,processingDetails",id=VIDEO).execute().get("items",[])
        if len(videos)!=1 or videos[0]["snippet"].get("channelId")!=CHANNEL:
            raise RuntimeError("Target video does not belong to FinTimes: no changes made")
        return videos[0]
    before=read()
    proc=before.get("processingDetails",{}).get("processingStatus")
    if proc!="succeeded":raise RuntimeError("Video not processed; cannot release: "+str(proc))
    current=before.get("status",{}).get("privacyStatus")
    print("PRE_RELEASING",json.dumps({
        "channel":channels[0]["snippet"]["title"],"video_id":VIDEO,"privacy":current,
        "scheduled":before.get("status",{}).get("publishAt"),
        "processing":proc,"title":before["snippet"]["title"]}),flush=True)
    if current!="public":
        allowed={"embeddable","license","publicStatsViewable","selfDeclaredMadeForKids","containsSyntheticMedia"}
        body={key:value for key,value in before["status"].items() if key in allowed}
        body["privacyStatus"]="public"
        yt.videos().update(part="status",body={"id":VIDEO,"status":body}).execute()
    for attempt in range(6):
        result=read()
        status=result.get("status",{})
        if status.get("privacyStatus")=="public":
            record({"status":"published_public","video_id":VIDEO,"watch_url":"https://www.youtube.com/watch?v="+VIDEO,
                    "channel_id":CHANNEL,"channel_title":channels[0]["snippet"]["title"],
                    "actual_privacy":status["privacyStatus"],
                    "processing_status":result.get("processingDetails",{}).get("processingStatus"),
                    "title":result["snippet"]["title"],
                    "thumbnail_sizes":list(result["snippet"].get("thumbnails",{}).keys()),
                    "captions_enabled":result.get("contentDetails",{}).get("caption"),
                    "scheduled_publish_at":status.get("publishAt")})
            return
        time.sleep(4)
    record({"status":"needs_reconciliation","video_id":VIDEO,"latest_privacy":result["status"].get("privacyStatus")})
    raise RuntimeError("Public readback did not confirm release")

if __name__=="__main__":
    main()
