"""Owner-requested removal of unverified-source identities from published text."""
import json,re
from pathlib import Path
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
import os
CHANNEL='UC9uSaourNW4ZAnlO4bRN_Cg'

def main():
    creds=Credentials(token=None,refresh_token=os.environ['YOUTUBE_REFRESH_TOKEN'],token_uri='https://oauth2.googleapis.com/token',client_id=os.environ['YOUTUBE_CLIENT_ID'],client_secret=os.environ['YOUTUBE_CLIENT_SECRET'],scopes=['https://www.googleapis.com/auth/youtube.force-ssl'])
    yt=build('youtube','v3',credentials=creds,cache_discovery=False)
    channels=yt.channels().list(part='id,contentDetails',mine=True).execute().get('items',[])
    if [c['id'] for c in channels]!=[CHANNEL]:raise RuntimeError('Wrong channel')
    playlist=channels[0]['contentDetails']['relatedPlaylists']['uploads']
    uploads=yt.playlistItems().list(part='snippet,contentDetails',playlistId=playlist,maxResults=50).execute().get('items',[])
    ids=[u['contentDetails']['videoId'] for u in uploads if u['snippet']['title'].startswith('UNVERIFIED:')]
    rows=yt.videos().list(part='snippet',id=','.join(ids)).execute().get('items',[]) if ids else []
    receipts=[]
    for row in rows:
        old=row['snippet']
        if old['channelId']!=CHANNEL:raise RuntimeError('Wrong video channel')
        title=re.sub(r'\s+from\s+@[A-Za-z0-9_]+','',old['title'])
        original=old.get('description','')
        handles=set(re.findall(r'@([A-Za-z0-9_]+)',original+' '+old['title']))
        authors=re.findall(r'^Original X author: (.+)$',original,re.M)
        names=re.findall(r'^Source: (.*?) \(@',original,re.M)
        text=[]
        for line in original.splitlines():
            if line.startswith(('Original X post:','Original X author:','Source:','Credit: X source:')):continue
            if re.search(r'https?://(?:www\.)?(?:x|twitter)\.com/',line):continue
            line=re.sub(r'\s+from\s+@[A-Za-z0-9_]+','',line)
            for name in handles|set(authors)|set(names):
                if name:line=re.sub(r'(?<!\w)@?'+re.escape(name)+r'(?!\w)','the source',line,flags=re.I)
            text.append(line)
        description='\n'.join(text).replace('Source image and link follow.','Source screenshot follows.')
        note='Original source credit appears only in the screenshot at the end of the video.'
        if note not in description:description+='\n'+note
        if title==old['title'] and description==original:continue
        snippet={k:v for k,v in old.items() if k in {'title','description','tags','categoryId','defaultLanguage','defaultAudioLanguage'}}
        snippet.update(title=title,description=description)
        snippet['tags']=[t for t in snippet.get('tags',[]) if not any(h.casefold() in t.casefold() for h in handles|set(authors))]
        if re.search(r'@[A-Za-z0-9_]+',title+' '+description):raise RuntimeError('Source handle still present')
        yt.videos().update(part='snippet',body={'id':row['id'],'snippet':snippet}).execute()
        actual=yt.videos().list(part='snippet',id=row['id']).execute()['items'][0]['snippet']
        if actual['title']!=title or actual['description']!=description:raise RuntimeError('Metadata update not confirmed')
        receipts.append({'videoId':row['id'],'previous_title':old['title'],'title':title,'verified':True})
    Path('source_identity_corrections.json').write_text(json.dumps(receipts,indent=2))
    print(json.dumps(receipts,indent=2))
if __name__=='__main__':main()
