"""Remove internal discovery attribution from existing channel descriptions."""
import json, os, re, time
from pathlib import Path
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
CHANNEL='UC9uSaourNW4ZAnlO4bRN_Cg'
LABEL=re.compile(r'^\s*(?:x\s+)?(?:discovery(?:\s+by)?|discovered\s+by)\s*:',re.I)

def clean(text):
    lines=[]
    for line in text.splitlines():
        if LABEL.match(line):
            # Preserve genuine source attribution on verified long editions.
            if re.match(r'^X discovery: @',line,re.I):
                lines.append(re.sub(r'^X discovery:', 'Original X post:',line,flags=re.I))
            continue
        lines.append(line)
    return '\n'.join(lines)

def main():
    creds=Credentials(token=None,refresh_token=os.environ['YOUTUBE_REFRESH_TOKEN'],token_uri='https://oauth2.googleapis.com/token',client_id=os.environ['YOUTUBE_CLIENT_ID'],client_secret=os.environ['YOUTUBE_CLIENT_SECRET'],scopes=['https://www.googleapis.com/auth/youtube.force-ssl'])
    yt=build('youtube','v3',credentials=creds,cache_discovery=False)
    channels=yt.channels().list(part='id,contentDetails',mine=True).execute().get('items',[])
    if [c['id'] for c in channels]!=[CHANNEL]:raise RuntimeError('Wrong channel')
    uploads=channels[0]['contentDetails']['relatedPlaylists']['uploads']
    ids=[];token=None
    while True:
        page=yt.playlistItems().list(part='contentDetails',playlistId=uploads,maxResults=50,pageToken=token).execute()
        ids.extend(item['contentDetails']['videoId'] for item in page.get('items',[]))
        token=page.get('nextPageToken')
        if not token:break
    receipts=[]
    Path('output').mkdir(exist_ok=True)
    for start in range(0,len(ids),50):
        videos=yt.videos().list(part='snippet,status',id=','.join(ids[start:start+50])).execute().get('items',[])
        for video in videos:
            old=video['snippet']
            if old['channelId']!=CHANNEL:raise RuntimeError('Wrong video channel')
            original=old.get('description','');description=clean(original)
            if description==original:continue
            if re.search(r'\bgemsearch\b',description,re.I):raise RuntimeError('Unexpected discovery attribution requires review')
            Path('output/before-'+video['id']+'.json').write_text(json.dumps(video,indent=2))
            snippet={k:v for k,v in old.items() if k in {'title','description','tags','categoryId','defaultLanguage','defaultAudioLanguage'}}
            snippet['description']=description
            yt.videos().update(part='snippet',body={'id':video['id'],'snippet':snippet}).execute()
            for attempt in range(8):
                current=yt.videos().list(part='snippet,status',id=video['id']).execute()['items'][0]
                if current['snippet']['description'].strip()==description.strip():break
                if attempt<7:time.sleep(4)
            else:raise RuntimeError('Description readback did not confirm correction: '+video['id'])
            if current['snippet']['title']!=old['title'] or current['status']['privacyStatus']!=video['status']['privacyStatus']:
                raise RuntimeError('Unexpected title or visibility change')
            receipts.append({'videoId':video['id'],'title':old['title'],'verified':True,'removed_lines':len(original.splitlines())-len(description.splitlines())})
            Path('output/discovery_corrections.json').write_text(json.dumps({'scanned':len(ids),'corrected':receipts},indent=2))
    # Full readback scan catches remaining internal labels in all channel uploads.
    for start in range(0,len(ids),50):
        for video in yt.videos().list(part='snippet',id=','.join(ids[start:start+50])).execute().get('items',[]):
            snippet=video['snippet'];text=snippet.get('description','')
            if any(LABEL.match(line) for line in text.splitlines()) or re.search(r'\bgemsearch\b',snippet['title']+' '+text,re.I):
                raise RuntimeError('Internal discovery attribution remains: '+video['id'])
    result={'scanned':len(ids),'corrected':receipts,'remaining_internal_discovery_labels':0}
    Path('output/discovery_corrections.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if __name__=='__main__':main()
