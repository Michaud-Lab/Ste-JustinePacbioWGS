import requests
import os,sys
import logging
import json
from configurator import Config

class Emedgene:
    """
    Return object for interacting with Emedgene's API
    """
    def __init__(self, config_file=os.path.expanduser(".myconf.json")):
        """
        Load settings from config_file, if provided. Define instance vars to
        provide more readable access to settings in dict "configs".
        """
        configs          = Config.from_path(config_file)
        self.username    = configs.Emedgene.username
        self.password    = configs.Emedgene.password
        self.prag_server = configs.Emedgene.endpoint
        # self.pheno_auth  = configs.Phenotips.auth
        # self.pheno_secret= configs.Phenotips.secret
        # self.pheno_url   = configs.Phenotips.endpoint


    def authenticate(self):
        """
        Returns an authorization token.
        N.B. The Authorization header expires after 8H, after that, requests
        will return an error code 403. To resolve, re-do the Login procedure to
        get a new token.
        """
        # TODO: Add different domain servers
        url      = f"{self.prag_server}/api/auth/api_login/"
        payload  = f'{{"username": "{self.username}", "password": "{self.password}"}}'
        headers  = {'Content-Type': 'application/json'}
        response = requests.request("POST", url, headers=headers, data=payload).json()
        if "Authorization" in response.keys():
            return response["Authorization"]
        else:
            logging.warning("Emedgene authentication failed:")
            print(response)
            sys.exit(1)

    def get_emg_id(self, sample):
        """
        Returns EMG identifier for Sample
        - `sample`: Sample Names (ex.: GMXXXXX, 24-XXXX-T1, MO-24-XXXXX...)
        - Returns : [str] ex.: EMGXXXXXXX, None (not found) or HTTPErrorCode
        """
        # TODO: Add different domain servers
        url = f"{self.prag_server}/api/sample/?query={sample}&sampleType=fastq"
        resp = requests.get(url, headers={'Authorization': self.authenticate()})
        if resp.status_code == 200:
            if resp.json()['total'] == 1:
                return resp.json()['hits'][0]['note']
            elif resp.json()['total'] == 0:
                return ""
            else:
                logging.warning(f"More than one Emedgene case found: {resp.json()['total']}")
                print(f"Returning the latest case involving sample {sample}: {resp.json()['hits'][-1]['note']}")

                return resp.json()['hits'][-1]['note']
        elif resp.status_code == 401 or resp.status_code == 403:
            logging.warning(f"Unauthorized: please authenticate yourself")
            return resp.status_code
        else:
            logging.warning(f"While fetching EMG ID, got the HTTP Error Code: [{resp.status_code}]\n{resp.text}")
            return resp.status_code


    def get_case_json(self, sample):
        """
        Returns the full json document for a case query, or the HTTP error code
        - `sample`: Case name on Emedgene, ex.: EMGXXXXXX
        - Returns : requests json object, None (not found) or HTTPErrorCode
        """
        url = f"{self.prag_server}/api/test/{sample}/"
        resp = requests.get(url, headers={'Authorization': self.authenticate()})
        if resp.status_code == 200:
            return resp.json()
        elif resp.status_code == 401 or resp.status_code == 403:
            logging.warning(f"Unauthorized: please authenticate yourself")
            return resp.status_code
        else:
            logging.warning(f"While fetching Case JSON, got the HTTP Error Code: [{resp.status_code}]\n{resp.text}")
            return resp.status_code

    def get_pheno_id(self, sample="", json_file=""):
        """
        Returns pheno identifier for Case
        - `json_file`: If file is given, we can extract the name from it. Not necessary if sample is given
        - `sample`: Case name (ex.: EMGXXXXXXX,...). Not necessary if json_file is provided
        - Returns : [str] ex.: P0000XXX.., None (not found) or HTTPErrorCode
        """
        #Generally, this will be because an error code was received
        if isinstance(json_file,int):
            logging.warning(f"Error code received instead of json file: {json_file}")
            return json_file

        if len(sample)==0 and len(json_file)==0:
            logging.warning(f"Either sample name or json file needed to extract pheno_id")
        #Get json_file using sample name
        elif len(json_file)==0:
            json_file = self.get_case_json(sample)
        #Get the notes from the json file
        if "notes" in json_file.keys():
            notes=json_file['notes']
            #We expect a format of pheno ID starting with P00...
            if notes[0:3]=="P00" and len(notes)==8:
                return notes
            else:
                start = notes.find("P0")
                end = notes.find("\n",start)
                corrected = notes[start:end]
                if len(corrected) == 8:
                    return corrected
                else:
                    logging.warning(f"pheno_id appears to be of a different format:{notes}")
                    return ""
        else:
            with open('error.json','w') as fp:
                json.dump(json_file,fp,indent=4)
            logging.warning(f"Pheno ID could not be found in json response. See error.json")

    #Phenotips is deprecated in favour of Qlin since we lost the subscription
    # def phenotips_import_HPO_request(self,pheno_id):
    #     """
    #     Returns a string containing the phenotype HPO terms of a patient
    #     - `pheno_id`: String of the Phenotips/Pragmatiq identifier ex.: P0000XXX... usually obtained from Emedgene
    #     - Returns : str HP:00XXXXX,HP:0000XXX,...
    #     """
    #     url=f"{self.pheno_url}/rest/patients/{pheno_id}"
    #     headers = {
    #         "accept": "application/json",
    #         "authorization": self.pheno_auth,
    #         "X-Gene42-Secret": self.pheno_secret
    #     }
    #     response = requests.get(url, headers=headers)
    #     data=response.json()

    #     #Parse the list for observed phenotypes (reject non observed ones)
    #     hpo_list=[]
    #     if "features" in data.keys():
    #         for terms in data["features"]:
    #             if terms["observed"] =='yes':
    #                 hpo_list.append(terms["id"])
    #     else:
    #         logging.warning(f"Features could not be found on Phenotips for sample {pheno_id}")

    #     return((",").join(hpo_list).replace('\'',""))

    def qlin_import_HPO_request(self,pheno_id):
        """
        Returns a string containing the phenotype HPO terms of a patient
        - `pheno_id`: String of the Phenotips/Pragmatiq identifier ex.: P0000XXX... usually obtained from Emedgene
        - Returns : str HP:00XXXXX,HP:0000XXX,...
        """
        url=f"{self.pheno_url}/rest/patients/{pheno_id}"
        headers = {
            "accept": "application/json",
            "authorization": self.pheno_auth,
            "X-Gene42-Secret": self.pheno_secret
        }
        response = requests.get(url, headers=headers)
        data=response.json()

        #Parse the list for observed phenotypes (reject non observed ones)
        hpo_list=[]
        if "features" in data.keys():
            for terms in data["features"]:
                if terms["observed"] =='yes':
                    hpo_list.append(terms["id"])
        else:
            logging.warning(f"Features could not be found on Phenotips for sample {pheno_id}")

        return((",").join(hpo_list).replace('\'',""))
