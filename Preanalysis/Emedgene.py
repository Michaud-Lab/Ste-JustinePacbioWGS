import requests
import os,sys
import logging
import json
import re
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

        self.database_tsv = configs.Phenotips.database_tsv


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
            if len(notes) == 0:
                return "No info"

            #We expect a format of pheno ID starting with P with 7 digits
            pattern = r"P\d{7}"
            if re.fullmatch(pattern, notes):
                return notes
            else:
                logging.warning(f"{sample} appears to be of a different format:{notes}")
                corrected = re.findall(pattern, notes)
                if len(corrected) != 0:
                    return corrected[0]
                else:
                    return ""
        else:
            with open('error.json','w') as fp:
                json.dump(json_file,fp,indent=4)
            logging.warning(f"Pheno ID could not be found in json response. See error.json")

    def phenotips_import_HPO_from_tsv(self, pheno_id):
        """
        Returns a string containing the phenotype HPO terms of a patient
        - `pheno_id`: String of the Phenotips identifier ex.: P0000XXX... usually obtained from Emedgene
        - Returns : str HP:00XXXXX,HP:0000XXX,...
        """
        hpo_list = []
        db_tsv = self.database_tsv
        if pheno_id is None or len(pheno_id) == 0:
            logging.warning(f"Phenotips ID is empty or None")
            return ""
        elif pheno_id == "No info":
            return pheno_id
        with open(db_tsv, 'r') as tsv_file:
            for line in tsv_file:
                if line.startswith(pheno_id):
                    # Extract HPO terms from the line
                    terms = line.strip().split('\t')[1:]
                    hpo_list.extend(terms)
        if len(hpo_list) == 0:
            logging.warning(f"No HPO terms found in TSV database for sample {pheno_id}")
            return pheno_id
        return (",").join(hpo_list).replace('\'',"")
